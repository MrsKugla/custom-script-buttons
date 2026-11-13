# Native Windows pickers for the Script Buttons block. Prints the choice on
# stdout (UTF-8, no newline) and nothing when the user cancels.
#   pick.ps1 file    script file   (CSB_INITIAL: current path, CSB_DIR: start folder)
#   pick.ps1 folder  config folder (CSB_INITIAL: current folder)
#   pick.ps1 color   color         (CSB_INITIAL: current #rrggbb) -> #rrggbb
param([string]$Mode = 'file')

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# An invisible topmost owner keeps the dialog in front of Tern.
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.StartPosition = 'CenterScreen'
$owner.FormBorderStyle = 'None'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Opacity = 0
$owner.Show()
$owner.Activate()

$initial = $env:CSB_INITIAL
$result = ''
switch ($Mode) {
	'file' {
		$d = New-Object System.Windows.Forms.OpenFileDialog
		$d.Title = 'Scegli lo script da lanciare'
		$d.Filter = 'Script (*.ps1;*.bat;*.cmd;*.py;*.pyw;*.exe;*.com;*.vbs;*.vbe;*.js;*.jse;*.wsf)|*.ps1;*.bat;*.cmd;*.py;*.pyw;*.exe;*.com;*.vbs;*.vbe;*.js;*.jse;*.wsf|Tutti i file (*.*)|*.*'
		if ($initial -and (Test-Path -LiteralPath $initial -PathType Leaf)) {
			$d.InitialDirectory = Split-Path -LiteralPath $initial -Parent
			$d.FileName = Split-Path -LiteralPath $initial -Leaf
		} elseif ($env:CSB_DIR -and (Test-Path -LiteralPath $env:CSB_DIR -PathType Container)) {
			$d.InitialDirectory = $env:CSB_DIR
		}
		if ($d.ShowDialog($owner) -eq 'OK') { $result = $d.FileName }
	}
	'folder' {
		$d = New-Object System.Windows.Forms.FolderBrowserDialog
		$d.Description = 'Cartella in cui salvare script-buttons.json'
		$d.ShowNewFolderButton = $true
		if ($initial -and (Test-Path -LiteralPath $initial -PathType Container)) { $d.SelectedPath = $initial }
		if ($d.ShowDialog($owner) -eq 'OK') { $result = $d.SelectedPath }
	}
	'color' {
		$d = New-Object System.Windows.Forms.ColorDialog
		$d.FullOpen = $true
		$d.AnyColor = $true
		if ($initial -match '^#([0-9a-fA-F]{6})$') {
			$d.Color = [System.Drawing.ColorTranslator]::FromHtml($initial)
		}
		if ($d.ShowDialog($owner) -eq 'OK') {
			$result = '#{0:x2}{1:x2}{2:x2}' -f $d.Color.R, $d.Color.G, $d.Color.B
		}
	}
}
$owner.Close()
[Console]::Out.Write($result)
