--!strict
-- Block `custom-script-buttons.board`: colored buttons that launch local
-- scripts, with the running script's output streamed under them.
--
-- The button list lives in `script-buttons.json`, in a folder chosen per
-- block (the pane's directory when the block opens, else asked first). The
-- file is re-read before every change, so blocks sharing a folder don't undo
-- each other's edits.
--
-- The buttons are one SVG (exact hex colors, alpha fill, solid border, and
-- the arrow between two linked buttons), with a grid of transparent hit areas
-- laid over it in the same proportions, so it stays aligned when it scales.

local ui = tern.ui

local CONFIG_NAME = "script-buttons.json"
local CELL_W, CELL_H, LANE, BTN_H, INSET = 200, 84, 28, 48, 6
local FILL_ALPHA = 0.22
local POLL_MS = 250
local ARROW_MS = 900
local MAX_OUT = 256 * 1024
local SAVED_OUT = 16 * 1024
local PRESETS = { "#7c6cf0", "#3b82f6", "#14b8a6", "#22c55e", "#eab308", "#f97316", "#ef4444", "#ec4899" }

type Button = { id: string, label: string, path: string, color: string, note: string }
type Field = { text: string, caret: number }
type FormKey = "label" | "path" | "note" | "color"
type Form = {
	id: string?,
	focus: FormKey,
	label: Field,
	path: Field,
	note: Field,
	color: Field,
	errs: { [string]: string },
}
type Run = {
	id: string,
	label: string,
	started: number,
	took: number?,
	status: number?,
	out: string,
	log: string,
	pidfile: string,
	stopped: boolean,
	input: string,
}
type State = {
	dir: string?,
	dirField: Field,
	buttons: { Button },
	err: string?,
	pick: string?,
	arrow: { from: string, to: string }?,
	form: Form?,
	confirm: string?,
	run: Run?,
	picking: boolean,
	stdin: Field,
}

-- Text fields: caret counted in code points, sent to Tern in UTF-16 units.

local function cplen(text: string): number
	return utf8.len(text) or #text
end

local function byteat(text: string, cp: number): number
	return utf8.offset(text, cp + 1) or (#text + 1)
end

local function units(text: string, cp: number): number
	local n, i = 0, 0
	for _, code in utf8.codes(text) do
		if i >= cp then
			break
		end
		n += if code > 0xFFFF then 2 else 1
		i += 1
	end
	return n
end

local function field(text: string): Field
	return { text = text, caret = cplen(text) }
end

local function finsert(f: Field, s: string)
	if utf8.len(s) == nil then
		return
	end
	local b = byteat(f.text, f.caret)
	f.text = string.sub(f.text, 1, b - 1) .. s .. string.sub(f.text, b)
	f.caret += cplen(s)
end

local function fedit(f: Field, key: Key): boolean
	local name = key.name
	if name == "backspace" then
		if f.caret > 0 then
			local a, b = byteat(f.text, f.caret - 1), byteat(f.text, f.caret)
			f.text = string.sub(f.text, 1, a - 1) .. string.sub(f.text, b)
			f.caret -= 1
		end
	elseif name == "delete" then
		if f.caret < cplen(f.text) then
			local a, b = byteat(f.text, f.caret), byteat(f.text, f.caret + 1)
			f.text = string.sub(f.text, 1, a - 1) .. string.sub(f.text, b)
		end
	elseif name == "left" then
		f.caret = math.max(0, f.caret - 1)
	elseif name == "right" then
		f.caret = math.min(cplen(f.text), f.caret + 1)
	elseif name == "home" then
		f.caret = 0
	elseif name == "end" then
		f.caret = cplen(f.text)
	elseif name == "paste" then
		finsert(f, (string.gsub(key.text or "", "[\r\n]+", " ")))
	elseif key.text and key.text ~= "" and not key.meta and (key.ctrl == key.alt) then
		-- ctrl+alt together is AltGr on European layouts (# @ [ ] on Italian).
		finsert(f, key.text)
	else
		return false
	end
	return true
end

local function input(key: string, f: Field, focused: boolean, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.key = key
	p.text = f.text
	p.cursor = if focused then units(f.text, f.caret) else nil
	return ui.node("input", p)
end

-- Paths and config file.

local function join(dir: string, name: string): string
	if string.match(dir, "[\\/]$") then
		return dir .. name
	end
	return dir .. "\\" .. name
end

local function basename(path: string): string
	return string.match(path, "([^\\/]+)[\\/]*$") or path
end

local function dirname(path: string): string?
	return string.match(path, "^(.*)[\\/][^\\/]*$")
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function normhex(s: string): string?
	local t = string.lower(trim(s))
	if string.sub(t, 1, 1) ~= "#" then
		t = "#" .. t
	end
	if string.match(t, "^#%x%x%x%x%x%x$") then
		return t
	end
	local r, g, b = string.match(t, "^#(%x)(%x)(%x)$")
	if r and g and b then
		return "#" .. r .. r .. g .. g .. b .. b
	end
	return nil
end

local function isdir(path: string): boolean
	local ok, _ = pcall(tern.fs.list, path)
	return ok
end

local function load(dir: string): ({ Button }, string?)
	local path = join(dir, CONFIG_NAME)
	if not tern.fs.exists(path) then
		return {}, nil
	end
	local ok, text = pcall(tern.fs.read, path, 1024 * 1024)
	if not ok then
		return {}, "Impossibile leggere " .. path
	end
	if string.sub(text, 1, 3) == "\239\187\191" then
		text = string.sub(text, 4)
	end
	local okj, data = pcall(tern.json.decode, text)
	if not okj or type(data) ~= "table" or type(data.buttons) ~= "table" then
		return {}, CONFIG_NAME .. " non è un JSON valido: correggilo o cancellalo, poi premi Ricarica"
	end
	local list: { Button } = {}
	local seen: { [string]: boolean } = {}
	for _, b in ipairs(data.buttons) do
		if type(b) == "table" and type(b.id) == "string" and not seen[b.id] then
			seen[b.id] = true
			table.insert(list, {
				id = b.id,
				label = if type(b.label) == "string" then b.label else "?",
				path = if type(b.path) == "string" then b.path else "",
				color = (if type(b.color) == "string" then normhex(b.color) else nil) or PRESETS[1],
				note = if type(b.note) == "string" then b.note else "",
			})
		end
	end
	return list, nil
end

local function store(dir: string, list: { Button })
	local out = {}
	for i, b in ipairs(list) do
		out[i] = { id = b.id, label = b.label, path = b.path, color = b.color, note = if b.note ~= "" then b.note else nil }
	end
	tern.fs.write(join(dir, CONFIG_NAME), tern.json.encode({ version = 1, buttons = tern.json.array(out) }, true) .. "\n")
end

local function find(list: { Button }, id: string): (number?, Button?)
	for i, b in ipairs(list) do
		if b.id == id then
			return i, b
		end
	end
	return nil, nil
end

-- Re-reads the file, applies `change` to the fresh list and writes it back.
-- Returns false (and shows why) when the file can't be used.
local function mutate(state: State, cx: BlockCx, change: ({ Button }) -> ()): boolean
	local dir = state.dir
	if not dir then
		return false
	end
	local list, err = load(dir)
	if err then
		state.err = err
		return false
	end
	change(list)
	local ok, werr = pcall(store, dir, list)
	if not ok then
		cx:toast("error", "Salvataggio non riuscito", tostring(werr))
		state.buttons = list
		return false
	end
	state.buttons, state.err = list, nil
	return true
end

local function usedir(state: State, cx: BlockCx, dir: string)
	state.dir = dir
	state.pick, state.arrow, state.form, state.confirm = nil, nil, nil, nil
	local list, err = load(dir)
	state.buttons, state.err = list, err
	if not err and not tern.fs.exists(join(dir, CONFIG_NAME)) then
		local ok, werr = pcall(store, dir, list)
		if not ok then
			state.err = "Impossibile creare " .. join(dir, CONFIG_NAME) .. ": " .. tostring(werr)
		end
	end
end

-- Processes.

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function ps(script: string): { string }
	return {
		"powershell.exe",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy",
		"Bypass",
		"-WindowStyle",
		"Hidden",
		"-File",
		join(tern.plugin.dir, script),
	}
end

-- How each kind of Windows script is started, by extension.
local function argv_for(path: string): { string }
	local ext = string.lower(string.match(path, "%.([%w]+)$") or "")
	if ext == "ps1" then
		return { "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path }
	elseif ext == "py" or ext == "pyw" then
		return { "python", "-u", path }
	elseif ext == "exe" or ext == "com" then
		return { path }
	elseif ext == "vbs" or ext == "vbe" or ext == "js" or ext == "jse" or ext == "wsf" then
		return { "cscript.exe", "//nologo", path }
	end
	-- .bat, .cmd and anything else: cmd runs it, through its file association if needed.
	return { "cmd.exe", "/d", "/c", path }
end

-- Runs pick.ps1 (`file`, `folder` or `color`) and hands back the choice, or nil.
local function picker(state: State, cx: BlockCx, mode: string, env: { [string]: string }, done: (string?) -> ())
	if state.picking then
		return
	end
	state.picking = true
	local argv = ps("pick.ps1")
	table.insert(argv, mode)
	tern.process.run(argv, { env = env }, function(r)
		state.picking = false
		if not alive(cx.pane) then
			return
		end
		local choice = trim(r.stdout)
		if r.status ~= 0 then
			cx:toast("error", "Selettore non riuscito", trim(r.stderr))
			cx:render()
			return
		end
		done(if choice ~= "" then choice else nil)
		cx:render()
	end)
end

local function readlog(run: Run)
	local ok, text = pcall(tern.fs.read, run.log)
	if ok then
		if #text > MAX_OUT then
			text = "…\n" .. string.sub(text, #text - MAX_OUT + 1)
		end
		run.out = text
	end
end

local function start(state: State, cx: BlockCx, b: Button)
	if state.run and state.run.status == nil then
		cx:toast("info", "«" .. state.run.label .. "» è ancora in esecuzione", "Fermalo o aspetta che finisca")
		return
	end
	if b.path == "" or not tern.fs.exists(b.path) then
		cx:toast("error", "Script non trovato", if b.path ~= "" then b.path else "Nessun percorso: modifica il bottone")
		return
	end
	-- Per run, not per pane: a script left running by a plugin reload must not
	-- read the next run's input or write into its log.
	local log = join(tern.plugin.data, string.format("run-%d-%d.log", cx.pane, math.floor(tern.now())))
	for _, name in ipairs(tern.fs.list(tern.plugin.data)) do
		if string.match(name, "^run%-" .. tostring(cx.pane) .. "[%-.]") then
			pcall(tern.fs.remove, join(tern.plugin.data, name))
		end
	end
	local run: Run = {
		id = b.id,
		label = b.label,
		started = tern.now(),
		out = "",
		log = log,
		pidfile = log .. ".pid",
		input = log .. ".in",
		stopped = false,
	}
	state.run = run
	pcall(tern.fs.write, run.input, "")
	pcall(tern.fs.write, log, "")
	local env = {
		CSB_ARGV = tern.json.encode(tern.json.array(argv_for(b.path))),
		CSB_LOG = log,
		CSB_PIDFILE = run.pidfile,
		CSB_INPUT = run.input,
		PYTHONUNBUFFERED = "1",
		-- Python's pipes default to the ANSI code page: ask for UTF-8 both ways.
		PYTHONIOENCODING = "utf-8",
		CSB_UTF8 = if string.match(string.lower(b.path), "%.pyw?$") then "1" else "0",
	}
	local ok, err = pcall(tern.process.run, ps("run.ps1"), { cwd = dirname(b.path), env = env }, function(r)
		if not alive(cx.pane) then
			return
		end
		readlog(run)
		local extra = trim(r.stderr)
		if extra ~= "" then
			run.out ..= "\27[31m" .. extra .. "\27[0m\n"
		end
		run.status = r.status
		run.took = tern.now() - run.started
		if state.run == run then
			cx:render()
		end
	end)
	if not ok then
		run.status, run.took = -1, 0
		run.out = "\27[31m" .. tostring(err) .. "\27[0m\n"
		return
	end
	local function tick()
		if state.run ~= run or run.status ~= nil or not alive(cx.pane) then
			return
		end
		local before = run.out
		readlog(run)
		if run.out ~= before then
			cx:render()
		end
		tern.timer(POLL_MS, tick)
	end
	tern.timer(POLL_MS, tick)
end

-- Sends the stdin line to the running script: run.ps1 forwards every new
-- complete line of the input file. The file only grows while the run lasts.
local function send(state: State, cx: BlockCx)
	local run = state.run
	if not run or run.status ~= nil then
		return
	end
	local line = string.gsub(state.stdin.text, "[\r\n]", " ")
	local ok, prev = pcall(tern.fs.read, run.input)
	local wok, err = pcall(tern.fs.write, run.input, (if ok then prev else "") .. line .. "\n")
	if not wok then
		cx:toast("error", "Input non inviato", tostring(err))
		return
	end
	state.stdin = field("")
end

local function stop(state: State, cx: BlockCx)
	local run = state.run
	if not run or run.status ~= nil then
		return
	end
	local ok, pid = pcall(tern.fs.read, run.pidfile)
	pid = if ok then trim(pid) else ""
	if not string.match(pid, "^%d+$") then
		cx:toast("error", "Impossibile fermare lo script", "PID non disponibile")
		return
	end
	run.stopped = true
	tern.process.run({ "taskkill.exe", "/PID", pid, "/T", "/F" }, {}, function(_r) end)
end

-- SVG drawing.

local function xml(s: string): string
	local t = string.gsub(s, "&", "&amp;")
	t = string.gsub(t, "<", "&lt;")
	t = string.gsub(t, ">", "&gt;")
	t = string.gsub(t, '"', "&quot;")
	return t
end

local function clip(s: string, max: number): string
	if cplen(s) <= max then
		return s
	end
	return string.sub(s, 1, byteat(s, max - 1) - 1) .. "…"
end

local function n(x: number): string
	return string.format("%.1f", x)
end

local function rect(x: number, y: number, label: string, color: string, dot: boolean?, running: boolean?, note: boolean?): string
	local w = CELL_W - 2 * INSET
	local parts = {
		string.format(
			'<rect class="%s" x="%s" y="%s" width="%d" height="%d" rx="8" fill="%s" fill-opacity="%s" stroke="%s" stroke-width="2"/>',
			if running then "csb-btn csb-running" else "csb-btn",
			n(x + INSET + 1),
			n(y + 1),
			w - 2,
			BTN_H - 2,
			color,
			if running then "0.42" else tostring(FILL_ALPHA),
			color
		),
		string.format(
			'<text class="csb-label" x="%s" y="%s" text-anchor="middle" font-family="Segoe UI, system-ui, sans-serif" font-size="14" font-weight="500" fill="#e8e8ea">%s</text>',
			n(x + CELL_W / 2),
			n(y + BTN_H / 2 + 5),
			xml(clip(label, 21))
		),
	}
	if note then
		-- Three short lines: "this button has a note", in its own color.
		local nx, ny = x + CELL_W - INSET - 17, y + BTN_H - 15
		table.insert(
			parts,
			string.format(
				'<path d="M%s %sh8M%s %sh8M%s %sh5" stroke="%s" stroke-width="1.6" stroke-linecap="round" opacity="0.85"/>',
				n(nx),
				n(ny),
				n(nx),
				n(ny + 3.5),
				n(nx),
				n(ny + 7),
				color
			)
		)
	end
	if dot ~= nil then
		table.insert(
			parts,
			string.format(
				'<circle class="%s" cx="%s" cy="%s" r="5" fill="%s" stroke="%s" stroke-width="1.5"/>',
				if dot then "csb-dot on" else "csb-dot",
				n(x + CELL_W - INSET - 13),
				n(y + 13),
				if dot then "#ef4444" else "none",
				if dot then "#ef4444" else "#9aa0a6"
			)
		)
	end
	return table.concat(parts)
end

local function arrow(ax: number, ay: number, bx: number, by: number, sameRow: boolean, color: string): string
	local d, tx, ty
	if sameRow then
		local cxp, cyp = (ax + bx) / 2, ay - 38
		d = string.format("M%s %s Q%s %s %s %s", n(ax), n(ay), n(cxp), n(cyp), n(bx), n(by))
		tx, ty = bx - cxp, by - cyp
	else
		local c1y, c2y = ay - 44, by - 44
		d = string.format("M%s %s C%s %s %s %s %s %s", n(ax), n(ay), n(ax), n(c1y), n(bx), n(c2y), n(bx), n(by))
		tx, ty = 0, by - c2y
	end
	local len = math.sqrt(tx * tx + ty * ty)
	if len == 0 then
		len = 1
	end
	local ux, uy = tx / len, ty / len
	local bxp, byp = bx - ux * 9, by - uy * 9
	local head = string.format(
		"M%s %s L%s %s L%s %s Z",
		n(bx),
		n(by),
		n(bxp - uy * 5),
		n(byp + ux * 5),
		n(bxp + uy * 5),
		n(byp - ux * 5)
	)
	return string.format(
		'<g class="csb-arrow"><path d="%s" fill="none" stroke="%s" stroke-width="2.2" stroke-linecap="round"/><path d="%s" fill="%s"/></g>',
		d,
		color,
		head,
		color
	)
end

local function gridsvg(state: State, cols: number): (string, number, number)
	local rows = math.ceil(#state.buttons / cols)
	local w, h = cols * CELL_W, rows * CELL_H
	local pos: { [string]: { number } } = {}
	local parts = {}
	local running = if state.run and state.run.status == nil then state.run.id else nil
	for i, b in ipairs(state.buttons) do
		local c, r = (i - 1) % cols, (i - 1) // cols
		local x, y = c * CELL_W, r * CELL_H + LANE
		pos[b.id] = { x, y, r }
		local lit = state.pick == b.id or (state.arrow ~= nil and (state.arrow.from == b.id or state.arrow.to == b.id))
		table.insert(parts, rect(x, y, b.label, b.color, lit, running == b.id, b.note ~= ""))
	end
	if state.arrow then
		local a, b = pos[state.arrow.from], pos[state.arrow.to]
		local _, src = find(state.buttons, state.arrow.from)
		if a and b and src then
			table.insert(parts, arrow(a[1] + CELL_W / 2, a[2] - 3, b[1] + CELL_W / 2, b[2] - 4, a[3] == b[3], src.color))
		end
	end
	local svg = string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>',
		w,
		h,
		w,
		h,
		table.concat(parts)
	)
	return svg, w, h
end

-- A keyed line of spans (the `text` builder takes no props).
local function textline(key: string, spans: { Span }): Node
	local node = ui.text(spans)
	local p: { [string]: any } = node.p or {}
	p.key = key
	node.p = p
	return node
end

local blobs: { [string]: string } = {}
local blobCount = 0

local function blob(cx: BlockCx, svg: string): string
	local id = blobs[svg]
	if not id then
		if blobCount > 64 then
			blobs, blobCount = {}, 0
		end
		id = cx:blob(svg, "image/svg+xml")
		blobs[svg] = id
		blobCount += 1
	end
	return id
end

-- Views.

local FORM_INPUTS: { [FormKey]: string } = {
	label = "layer.form.f_label.label",
	path = "layer.form.f_path.r.path",
	note = "layer.form.f_note.note",
	color = "layer.form.f_color.r.color",
}
local SETUP_INPUT = "main.setup.f.r.dir"
local STDIN_INPUT = "main.run.stdin.line"
local FORM_ORDER: { FormKey } = { "label", "path", "note", "color" }

local function focus(cx: BlockCx, id: string)
	cx:render()
	cx:frame({ { "focus", id } })
end

local function menu(b: Button, i: number, total: number): { any }
	return {
		{ header = b.label },
		{ id = "edit=" .. b.id, label = "Modifica…", icon = "pen" },
		{ id = "left=" .. b.id, label = "Sposta indietro", icon = "arrow-left", disabled = i == 1 },
		{ id = "right=" .. b.id, label = "Sposta avanti", icon = "arrow-right", disabled = i == total },
		"-",
		{ id = "del=" .. b.id, label = "Elimina", icon = "trash", danger = true },
	}
end

local function gridview(state: State, cx: BlockCx): Node
	local count = #state.buttons
	local fit = math.max(1, math.min(12, (cx.cols * 8 - 16) // CELL_W))
	local cols = math.max(1, math.min(count, fit))
	local svg, w, h = gridsvg(state, cols)
	local cells = {}
	for i, b in ipairs(state.buttons) do
		local card = { ui.text({ ui.span(b.label, "strong") }) }
		if b.note ~= "" then
			table.insert(card, ui.md(b.note))
		end
		table.insert(card, ui.text({ ui.span(b.path, "muted path") }))
		table.insert(card, ui.text({ ui.span("tasto destro: modifica", "dim") }))
		table.insert(
			cells,
			ui.el("div", { key = b.id, class = "csb-cell" }, {
				ui.el("div", {
					key = "hit",
					class = "csb-hit",
					role = "csb.hit",
					hovercard = ui.col(card),
					actions = { click = "run=" .. b.id, menu = menu(b, i, count) },
				}),
				ui.el("div", {
					key = "dot",
					class = "csb-dothit",
					role = "csb.dot",
					title = "Collega per scambiare",
					actions = { click = "pick=" .. b.id },
				}),
			})
		)
	end
	return ui.node("image", {
		key = "grid",
		role = "csb.grid",
		blob = blob(cx, svg),
		alt = "Bottoni script",
		w = w,
		h = h,
		actions = { click = "noop" },
	}, {
		ui.el("div", { key = "hits", class = "csb-hits csb-n" .. tostring(cols) }, cells),
	})
end

local function runview(state: State): Node?
	local run = state.run
	if not run then
		return nil
	end
	local status: Node
	local tone, icon
	local controls = {}
	if run.status == nil then
		tone, icon = "pending", "play"
		status = ui.row({
			ui.node("spinner", { style = "dots", label = { ui.span("In esecuzione", "pending") } }),
			ui.node("elapsed", { age = tern.now() - run.started }),
		})
		table.insert(controls, ui.button("Ferma", { size = "sm", variant = "danger", icon = "stop", actions = { click = "stop" } }))
	else
		local secs = string.format("%.1fs", (run.took or 0) / 1000)
		local word
		if run.status == 0 then
			tone, icon, word = "success", "check", "Completato"
		elseif run.stopped then
			tone, icon, word = "warning", "stop", "Fermato"
		elseif run.status == -2 then
			tone, icon, word = "warning", "warn", "Interrotto (plugin ricaricato)"
		else
			tone, icon, word = "error", "x-circle", "Errore · exit " .. tostring(run.status)
		end
		status = ui.row({
			ui.badge(word, tone),
			ui.text({ ui.span(if run.status == -2 then "" else secs, "muted mono") }),
		})
		table.insert(controls, ui.button("Rilancia", { size = "sm", icon = "repeat", actions = { click = "run=" .. run.id } }))
		table.insert(controls, ui.button("Pulisci", { size = "sm", variant = "quiet", icon = "eraser", actions = { click = "clear" } }))
	end
	local endrow = ui.node("row", { key = "end", gap = "xs" }, controls)
	local body: Node = if run.out == ""
		then textline("wait", { ui.span(if run.status == nil then "In attesa di output…" else "(nessun output)", "muted") })
		else ui.node("ansi", { key = "out", text = run.out, follow = true, max = { h = "18lines" } })
	local parts = { endrow, status, body }
	if run.status == nil then
		table.insert(
			parts,
			ui.node("row", { key = "stdin", align = "start" }, {
				ui.node("editor", {
					key = "line",
					text = state.stdin.text,
					cursor = units(state.stdin.text, state.stdin.caret),
					prompt = { ui.span("› ", "accent") },
					placeholder = "Input per lo script: scrivi e premi Invio",
					grow = 1,
					basis = 0,
					role = "csb.stdin",
				}),
				ui.button("Invia", { size = "sm", icon = "send", keys = { "enter" }, actions = { click = "send" } }),
			})
		)
	end
	return ui.card({ ui.span(run.label, "strong") }, parts, {
		key = "run",
		icon = icon,
		tone = tone,
		["end"] = "main.run.end",
	})
end

local function setupview(state: State): Node
	return ui.node("col", { key = "setup", gap = "md" }, {
		ui.node("empty", {
			key = "e",
			icon = "folder",
			title = "Dove salvo la configurazione?",
			text = "Scegli la cartella in cui creare " .. CONFIG_NAME .. ".",
		}, {
			ui.button("Scegli cartella…", {
				variant = "primary",
				icon = "folder-open",
				busy = state.picking,
				actions = { click = "pickdir" },
			}),
		}),
		ui.node("field", { key = "f", label = "Oppure scrivi il percorso", error = state.err }, {
			ui.node("row", { key = "r", role = "csb.fieldrow" }, {
				input("dir", state.dirField, true, { placeholder = "C:\\percorso\\cartella", grow = 1, basis = 0, role = "csb.wide", mono = true }),
				ui.button("Usa", { icon = "check", keys = { "enter" }, actions = { click = "setdir" } }),
			}),
		}),
	})
end

local function formview(state: State, cx: BlockCx): Node?
	local f = state.form
	if not f then
		return nil
	end
	local color = normhex(f.color.text)
	local swatches = {}
	for i, hex in ipairs(PRESETS) do
		table.insert(
			swatches,
			ui.el("div", {
				key = "s" .. i,
				class = "csb-sw csb-sw-" .. i .. (if color == hex then " on" else ""),
				role = "csb.swatch",
				title = hex,
				actions = { click = "preset=" .. hex },
			})
		)
	end
	local preview: Node
	if color then
		local svg = string.format(
			'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>',
			CELL_W,
			BTN_H,
			CELL_W,
			BTN_H,
			rect(0, 0, if trim(f.label.text) ~= "" then f.label.text else "Anteprima", color)
		)
		preview = ui.node("image", { key = "preview", blob = blob(cx, svg), alt = "Anteprima", w = CELL_W, h = BTN_H, actions = { click = "noop" } })
	else
		preview = textline("preview", { ui.span("Anteprima: colore non valido", "muted") })
	end
	return ui.node("overlay", {
		key = "form",
		head = if f.id then "Modifica bottone" else "Nuovo bottone",
		icon = if f.id then "pen" else "plus",
		size = "md",
		modal = true,
		foot = "layer.form.foot",
	}, {
		ui.node("field", { key = "f_label", label = "Etichetta", required = true, error = f.errs.label }, {
			input("label", f.label, f.focus == "label", { placeholder = "Backup NAS" }),
		}),
		ui.node("field", {
			key = "f_path",
			label = "Script",
			required = true,
			error = f.errs.path,
			hint = ".ps1, .bat, .cmd, .py, .exe, .vbs, .js, .wsf",
		}, {
			ui.node("row", { key = "r", role = "csb.fieldrow" }, {
				input("path", f.path, f.focus == "path", { placeholder = "C:\\script\\backup.ps1", grow = 1, basis = 0, role = "csb.wide", mono = true }),
				ui.button("Sfoglia…", { icon = "folder-open", busy = state.picking, actions = { click = "browse" } }),
			}),
		}),
		ui.node("field", { key = "f_note", label = "Note", hint = "Quando lanciarlo, cosa fa… Maiusc+Invio per andare a capo" }, {
			ui.node("editor", {
				key = "note",
				text = f.note.text,
				cursor = if f.focus == "note" then units(f.note.text, f.note.caret) else nil,
				placeholder = "Da lanciare a fine mese, dopo la chiusura contabile",
				maxLines = 5,
			}),
		}),
		ui.node("field", { key = "f_color", label = "Colore", error = f.errs.color }, {
			ui.node("row", { key = "r" }, {
				ui.node("row", { key = "sw", gap = "xs" }, swatches),
				input("color", f.color, f.focus == "color", { mono = true, min = { w = "9ch" }, max = { w = "11ch" } }),
				ui.button("Scegli…", { icon = "palette", busy = state.picking, actions = { click = "colorpick" } }),
			}),
		}),
		preview,
		ui.node("row", { key = "foot", gap = "sm", justify = "end" }, {
			ui.button("Annulla", { variant = "quiet", keys = { "esc" }, actions = { click = "cancel" } }),
			ui.button("Salva", { variant = "primary", keys = { "enter" }, actions = { click = "save" } }),
		}),
	})
end

local function confirmview(state: State): Node?
	if not state.confirm then
		return nil
	end
	local _, b = find(state.buttons, state.confirm)
	if not b then
		return nil
	end
	return ui.node("overlay", {
		key = "confirm",
		icon = "trash",
		head = "Eliminare «" .. b.label .. "»?",
		size = "sm",
		modal = true,
		foot = "layer.confirm.foot",
	}, {
		ui.text({ ui.span("Lo script resta sul disco: si toglie solo il bottone.", "muted") }),
		ui.node("row", { key = "foot", gap = "sm", justify = "end" }, {
			ui.button("Annulla", { variant = "quiet", keys = { "esc" }, actions = { click = "canceldel" } }),
			ui.button("Elimina", { variant = "danger", keys = { "enter" }, actions = { click = "confirmdel" } }),
		}),
	})
end

local function hint(state: State): Node
	if state.arrow then
		return textline("hint", { ui.span("Scambio in corso…", "accent") })
	end
	if state.pick then
		local _, b = find(state.buttons, state.pick)
		return textline("hint", {
			ui.span("Clicca il pallino del bottone da scambiare con «" .. (if b then b.label else "?") .. "»  ", "accent"),
			ui.span("esc", "key"),
			ui.span(" annulla", "muted"),
		})
	end
	return textline("hint", {
		ui.span("Clic: lancia · pallino → pallino: scambia · tasto destro: modifica, sposta, elimina", "muted"),
	})
end

local function mainview(state: State, cx: BlockCx): Node
	local dir = state.dir
	if not dir then
		return ui.col({ setupview(state) })
	end
	local children = {
		ui.node("row", { key = "head", justify = "between" }, {
			ui.text({ ui.span("Script", "title"), ui.span("  "), ui.span(join(dir, CONFIG_NAME), "muted path") }),
			ui.node("row", { key = "tools", gap = "xs" }, {
				ui.button("Nuovo", { icon = "plus", variant = "primary", size = "sm", actions = { click = "new" } }),
				ui.button("", { icon = "repeat", size = "sm", variant = "quiet", title = "Ricarica il file", actions = { click = "reload" } }),
				ui.button("", {
					icon = "folder",
					size = "sm",
					variant = "quiet",
					title = "Cambia cartella",
					busy = state.picking and state.form == nil,
					actions = { click = "pickdir" },
				}),
			}),
		}),
	}
	if state.err then
		table.insert(
			children,
			ui.node("empty", { key = "err", variant = "inline", frame = true, tone = "error", icon = "warn", text = state.err }, {
				ui.button("Ricarica", { variant = "quiet", size = "sm", actions = { click = "reload" } }),
			})
		)
	elseif #state.buttons == 0 then
		table.insert(
			children,
			ui.node("empty", {
				key = "none",
				icon = "run",
				title = "Nessun bottone",
				text = "Aggiungi un bottone per lanciare uno script.",
			}, {
				ui.button("Nuovo bottone", { variant = "primary", icon = "plus", actions = { click = "new" } }),
			})
		)
	else
		table.insert(children, hint(state))
		table.insert(children, gridview(state, cx))
	end
	local run = runview(state)
	if run then
		table.insert(children, run)
	end
	return ui.node("col", { gap = "md" }, children)
end

-- Handlers.

local function openform(state: State, cx: BlockCx, b: Button?)
	local color = if b then b.color else PRESETS[(#state.buttons % #PRESETS) + 1]
	state.form = {
		id = if b then b.id else nil,
		focus = "label",
		label = field(if b then b.label else ""),
		path = field(if b then b.path else ""),
		note = field(if b then b.note else ""),
		color = field(color),
		errs = {},
	}
	focus(cx, FORM_INPUTS.label)
end

local function saveform(state: State, cx: BlockCx)
	local f = state.form
	if not f then
		return
	end
	local label, path = trim(f.label.text), trim(f.path.text)
	local note = trim(f.note.text)
	path = string.gsub(path, '^"(.*)"$', "%1")
	local color = normhex(f.color.text)
	f.errs = {}
	if label == "" then
		f.errs.label = "Scrivi un'etichetta"
	end
	if path == "" then
		f.errs.path = "Scegli lo script"
	elseif not tern.fs.exists(path) then
		f.errs.path = "File non trovato"
	end
	if not color then
		f.errs.color = "Colore hex, ad esempio #7c6cf0"
	end
	if next(f.errs) then
		return
	end
	local id = f.id
	local ok = mutate(state, cx, function(list)
		local b: Button? = nil
		if id then
			_, b = find(list, id)
		end
		if b then
			b.label, b.path, b.color, b.note = label, path, color :: string, note
			return
		end
		local top = 0
		for _, x in ipairs(list) do
			top = math.max(top, tonumber(string.match(x.id, "^b(%d+)$")) or 0)
		end
		table.insert(list, { id = "b" .. tostring(top + 1), label = label, path = path, color = color :: string, note = note })
	end)
	if ok then
		state.form = nil
	end
end

local function swap(state: State, cx: BlockCx, a: string, b: string)
	mutate(state, cx, function(list)
		local i = find(list, a)
		local j = find(list, b)
		if i and j then
			list[i], list[j] = list[j], list[i]
		end
	end)
end

local function pick(state: State, cx: BlockCx, id: string)
	if state.arrow then
		return
	end
	if not state.pick then
		state.pick = id
		return
	end
	if state.pick == id then
		state.pick = nil
		return
	end
	local from = state.pick
	state.pick = nil
	local link = { from = from, to = id }
	state.arrow = link
	tern.timer(ARROW_MS, function()
		if state.arrow ~= link or not alive(cx.pane) then
			return
		end
		state.arrow = nil
		swap(state, cx, link.from, link.to)
		cx:render()
	end)
end

local function formkey(state: State, f: Form, key: Key, cx: BlockCx): boolean
	if key.name == "escape" then
		state.form = nil
	elseif key.name == "enter" and key.shift and f.focus == "note" then
		finsert(f.note, "\n")
	elseif key.name == "paste" and f.focus == "note" then
		finsert(f.note, (string.gsub(key.text or "", "\r\n?", "\n")))
	elseif key.name == "enter" then
		saveform(state, cx)
	elseif key.name == "tab" then
		local at = table.find(FORM_ORDER, f.focus) or 1
		local step = if key.shift then -1 else 1
		f.focus = FORM_ORDER[((at - 1 + step) % #FORM_ORDER) + 1]
		focus(cx, FORM_INPUTS[f.focus])
	else
		local fld = f[f.focus] :: Field
		return fedit(fld, key)
	end
	return true
end

local board: BlockDef<State> = {
	font = "sans",
	init = function(cx, args, saved)
		local state: State = {
			dir = nil,
			dirField = field(""),
			stdin = field(""),
			buttons = {},
			err = nil,
			pick = nil,
			arrow = nil,
			form = nil,
			confirm = nil,
			run = nil,
			picking = false,
		}
		local dir: string? = nil
		if type(saved) == "table" and type(saved.dir) == "string" then
			dir = saved.dir
		elseif type(args[1]) == "string" and isdir(args[1]) then
			dir = args[1]
		elseif cx.cwd and isdir(cx.cwd) then
			dir = cx.cwd
		end
		if dir then
			usedir(state, cx, dir)
		end
		if type(saved) == "table" and type(saved.last) == "table" then
			local l = saved.last
			state.run = {
				id = if type(l.id) == "string" then l.id else "",
				label = if type(l.label) == "string" then l.label else "?",
				started = 0,
				took = if type(l.took) == "number" then l.took else 0,
				status = if type(l.status) == "number" then l.status else -2,
				out = if type(l.out) == "string" then l.out else "",
				log = "",
				pidfile = "",
				input = "",
				stopped = l.stopped == true,
			}
		end
		return state
	end,
	title = function(state)
		if state.run and state.run.status == nil then
			return "▶ " .. state.run.label
		end
		return if state.dir then "Script · " .. basename(state.dir) else "Script Buttons"
	end,
	view = function(state, cx)
		local layer = formview(state, cx) or confirmview(state)
		return {
			main = mainview(state, cx),
			layer = if layer then ui.col({ layer }) else nil,
		}
	end,
	key = function(state, key, cx)
		local f = state.form
		if f then
			return formkey(state, f, key, cx)
		end
		if state.confirm then
			if key.name == "escape" then
				state.confirm = nil
			elseif key.name == "enter" then
				local id = state.confirm
				state.confirm = nil
				mutate(state, cx, function(list)
					local i = find(list, id :: string)
					if i then
						table.remove(list, i)
					end
				end)
			else
				return false
			end
			return true
		end
		if not state.dir then
			if key.name == "enter" then
				local dir = trim(state.dirField.text)
				if isdir(dir) then
					usedir(state, cx, dir)
				else
					state.err = "Cartella non trovata"
				end
				return true
			end
			return fedit(state.dirField, key)
		end
		if state.run and state.run.status == nil then
			if key.name == "enter" then
				send(state, cx)
				return true
			end
			if key.name ~= "escape" and fedit(state.stdin, key) then
				return true
			end
		end
		if key.name == "escape" and (state.pick or state.arrow) then
			state.pick, state.arrow = nil, nil
			return true
		end
		return false
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" then
			local f = state.form
			if f then
				for k, id in pairs(FORM_INPUTS) do
					if id == ev.id then
						f.focus = k
						focus(cx, id)
					end
				end
			elseif ev.id == STDIN_INPUT then
				focus(cx, STDIN_INPUT)
			elseif ev.id == SETUP_INPUT then
				focus(cx, SETUP_INPUT)
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		if act == "noop" then
			return
		elseif act == "send" then
			send(state, cx)
		elseif act == "run" then
			local _, b = find(state.buttons, value)
			if b then
				state.pick = nil
				start(state, cx, b)
				if state.run and state.run.status == nil and state.run.id == b.id then
					state.stdin = field("")
					focus(cx, STDIN_INPUT)
				end
			end
		elseif act == "pick" then
			pick(state, cx, value)
		elseif act == "new" then
			openform(state, cx, nil)
		elseif act == "edit" then
			local _, b = find(state.buttons, value)
			if b then
				openform(state, cx, b)
			end
		elseif act == "left" or act == "right" then
			mutate(state, cx, function(list)
				local i = find(list, value)
				local j = if i then (if act == "left" then i - 1 else i + 1) else nil
				if i and j and j >= 1 and j <= #list then
					list[i], list[j] = list[j], list[i]
				end
			end)
		elseif act == "del" then
			state.confirm = value
		elseif act == "confirmdel" then
			local id = state.confirm
			state.confirm = nil
			if id then
				mutate(state, cx, function(list)
					local i = find(list, id)
					if i then
						table.remove(list, i)
					end
				end)
			end
		elseif act == "canceldel" then
			state.confirm = nil
		elseif act == "reload" then
			if state.dir then
				usedir(state, cx, state.dir)
			end
		elseif act == "pickdir" then
			picker(state, cx, "folder", { CSB_INITIAL = state.dir or cx.cwd or "" }, function(dir)
				if dir then
					usedir(state, cx, dir)
				end
			end)
		elseif act == "setdir" then
			local dir = trim(state.dirField.text)
			if isdir(dir) then
				usedir(state, cx, dir)
			else
				state.err = "Cartella non trovata"
			end
		elseif act == "stop" then
			stop(state, cx)
		elseif act == "clear" then
			if state.run and state.run.status ~= nil then
				state.run = nil
			end
		elseif act == "save" then
			saveform(state, cx)
		elseif act == "cancel" then
			state.form = nil
		elseif act == "preset" then
			local f = state.form
			if f and value then
				f.color = field(value)
				f.errs.color = nil
			end
		elseif act == "browse" then
			local f = state.form
			if f then
				picker(state, cx, "file", { CSB_INITIAL = trim(f.path.text), CSB_DIR = state.dir or "" }, function(path)
					if path and state.form == f then
						f.path = field(path)
						f.errs.path = nil
						if trim(f.label.text) == "" then
							f.label = field((string.gsub(basename(path), "%.[^.]*$", "")))
						end
					end
				end)
			end
		elseif act == "colorpick" then
			local f = state.form
			if f then
				picker(state, cx, "color", { CSB_INITIAL = normhex(f.color.text) or "" }, function(hex)
					if hex and state.form == f then
						f.color = field(hex)
						f.errs.color = nil
					end
				end)
			end
		end
	end,
	save = function(state)
		local last = nil
		local run = state.run
		if run and run.status ~= nil then
			local out = run.out
			if #out > SAVED_OUT then
				out = "…\n" .. string.sub(out, #out - SAVED_OUT + 1)
			end
			last = { id = run.id, label = run.label, status = run.status, took = run.took, out = out, stopped = run.stopped }
		elseif run then
			-- Still running: a reload or restart loses the process callback.
			last = { id = run.id, label = run.label, out = "" }
		end
		return { dir = state.dir, last = last }
	end,
}

tern.block.define("board", board)
