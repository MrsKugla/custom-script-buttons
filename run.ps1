# Runs one script for the Script Buttons block: streams its output to a log
# file the block polls, and feeds it the lines the block writes to an input
# file. Inputs come through the environment (no quoting issues):
#   CSB_ARGV     JSON array: the program and its arguments
#   CSB_LOG      file that receives the output as it arrives (UTF-8)
#   CSB_INPUT    file the block appends lines to; each new complete line is
#                written to the script's stdin and echoed to the log
#   CSB_PIDFILE  file that receives this process id, so the block can stop the tree
# Exit status: the script's own exit code, 1 when it could not start.

$log = $env:CSB_LOG
$inFile = $env:CSB_INPUT
[IO.File]::WriteAllText($log, '')
if ($env:CSB_PIDFILE) { [IO.File]::WriteAllText($env:CSB_PIDFILE, "$PID") }

$esc = [char]27
function Write-Log([string]$text) {
	[IO.File]::AppendAllText($log, $text)
}

# One argument quoted for CreateProcess (CommandLineToArgvW rules).
function Quote([string]$a) {
	if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
	$s = $a -replace '(\\*)"', '$1$1\"'
	$s = $s -replace '(\\+)$', '$1$1'
	return '"' + $s + '"'
}

# Parameter form, not the pipeline: PowerShell 5.1 would wrap the array in another one.
$argv = [object[]](ConvertFrom-Json $env:CSB_ARGV)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $argv[0]
$psi.Arguments = (@($argv | Select-Object -Skip 1) | ForEach-Object { Quote $_ }) -join ' '
$psi.WorkingDirectory = (Get-Location).Path
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# Python is told to speak UTF-8 (CSB_UTF8=1); cmd, PowerShell and most .exe use the OEM code page.
$enc = if ($env:CSB_UTF8 -eq '1') { New-Object System.Text.UTF8Encoding($false) } else { [Console]::OutputEncoding }
$psi.StandardOutputEncoding = $enc
$psi.StandardErrorEncoding = $enc

try {
	$p = [System.Diagnostics.Process]::Start($psi)
} catch {
	Write-Log "$esc[31m$($_.Exception.InnerException.Message)$esc[0m`n"
	exit 1
}
# .NET Framework has no StandardInputEncoding: write the pipe through our own writer.
$stdin = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, $enc)
$stdin.AutoFlush = $true
$mark = [string][char]0x203A

# Chunks, not lines, so a prompt without a newline ("Nome: ") shows at once.
$size = 4096
$bufOut = New-Object char[] $size
$bufErr = New-Object char[] $size
$readOut = $p.StandardOutput.ReadAsync($bufOut, 0, $size)
$readErr = $p.StandardError.ReadAsync($bufErr, 0, $size)
$outDone = $false
$errDone = $false
$offset = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)

while (-not ($outDone -and $errDone)) {
	$busy = $false
	if (-not $outDone -and $readOut.IsCompleted) {
		$n = $readOut.Result
		if ($n -le 0) { $outDone = $true } else {
			Write-Log (New-Object string($bufOut, 0, $n))
			$readOut = $p.StandardOutput.ReadAsync($bufOut, 0, $size)
		}
		$busy = $true
	}
	if (-not $errDone -and $readErr.IsCompleted) {
		$n = $readErr.Result
		if ($n -le 0) { $errDone = $true } else {
			Write-Log "$esc[31m$(New-Object string($bufErr, 0, $n))$esc[0m"
			$readErr = $p.StandardError.ReadAsync($bufErr, 0, $size)
		}
		$busy = $true
	}
	if ($inFile -and -not $p.HasExited) {
		$bytes = $null
		try { $bytes = [IO.File]::ReadAllBytes($inFile) } catch { }
		if ($bytes -and $bytes.Length -gt $offset) {
			# Only complete lines: the block may be rewriting the file right now.
			$last = -1
			for ($i = $bytes.Length - 1; $i -ge $offset; $i--) {
				if ($bytes[$i] -eq 10) { $last = $i; break }
			}
			if ($last -ge $offset) {
				$chunk = $utf8.GetString($bytes, $offset, $last - $offset)
				$offset = $last + 1
				foreach ($line in ($chunk -split "`n")) {
					Write-Log "$esc[36m$mark $line$esc[0m`n"
					try { $stdin.WriteLine($line) } catch { }
				}
				$busy = $true
			}
		}
	}
	if (-not $busy) { Start-Sleep -Milliseconds 40 }
}

$p.WaitForExit()
exit $p.ExitCode
