#!/usr/bin/env bash
# test-clipd-win.sh — sp039 Task 7 end-to-end against this WSL host's own
# Windows side: builds clipd.exe, runs `clipd.exe agent windows` from a
# throwaway %TEMP% dir with its own config/folder/state, drives the real
# Windows clipboard from PowerShell, and checks:
#
#   plain copy            → exactly 1 entry, listed by a peer view
#   KeePass-style copy    → 0 entries (ExcludeClipboardContentFromMonitorProcessing)
#   5-copy burst          → 5 entries
#   bitmap copy (DIB)     → 1 image/png entry ([image WxH])
#   pick <id> / --latest  → text matches, both exclusion formats = DWORD 0,
#                           agent writes no entry for the pick (echo guard)
#   pick of unknown id    → exit 1
#
# Side effects are bounded: the user's clipboard is snapshotted in memory
# (every renderable format) and restored in a finally block; test copies
# carry CanIncludeInClipboardHistory=0 / CanUploadToCloudClipboard=0 so they
# stay out of Win+V history and the cloud; nothing is installed, no
# scheduled task, no firewall rule (clipd never listens). The only process
# started is our agent, killed by the pid we recorded — and the trap below
# kills that pid only if its image is our temp clipd.exe.
#
# Note: other clipboard watchers (e.g. clip-win-bridge) observe the test
# copies like any other copy and may set the clipboard back to an earlier
# one; they are not touched, and the echo checks count copies of the picked
# content rather than total entries so such a re-set is not a failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
GO=${GO:-$(command -v go || echo /sbin/go)}
command -v powershell.exe >/dev/null || { echo "SKIP: no powershell.exe (not WSL?)"; exit 0; }

psh() { powershell.exe -NoProfile -NonInteractive "$@" | tr -d '\r'; }

wintemp=$(psh -Command '[IO.Path]::GetTempPath()')
name="clipd-test-$$-$RANDOM"
windir="${wintemp%\\}\\$name"
lindir=$(wslpath -u "$windir")

cleanup() {
	local rc=$?
	if [ -f "$lindir/agent.pid" ]; then
		local pid
		pid=$(tr -dc 0-9 <"$lindir/agent.pid")
		# Guard first: kill only if that pid is still OUR temp clipd.exe.
		[ -n "$pid" ] && psh -Command "\$p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if (\$p -and \$p.Path -eq '$windir\\clipd.exe') { Stop-Process -Id $pid -Force; 'killed leftover agent $pid' }" || true
	fi
	rm -rf "$lindir"
	exit "$rc"
}
trap cleanup EXIT

mkdir -p "$lindir"
(cd "$here" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$GO" build -o "$lindir/clipd.exe" ./cmd/clipd)

# Another two-way Windows clipboard syncer (the user's clip-win-bridge)
# re-sets earlier copies; with it running, per-copy counts are "at least 1".
bridge=0
pgrep -u "$(id -u)" -f 'clip-win-bridge\.sh' >/dev/null 2>&1 && bridge=1
printf '\xEF\xBB\xBF' >"$lindir/t.ps1"   # BOM: Windows PowerShell 5.1 reads BOM-less as ANSI
cat >>"$lindir/t.ps1" <<'PS1'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8   # clipd prints UTF-8
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$dir = $PSScriptRoot
$exe = Join-Path $dir 'clipd.exe'
$env:CLIPD_CONFIG_DIR = "$dir\cfg"
$env:CLIPD_FOLDER     = "$dir\folder"
$env:CLIPD_STATE_DIR  = "$dir\state"
$env:CLIPD_DEVICE     = 'wintest'
New-Item -ItemType Directory "$dir\folder" | Out-Null
$script:fail = 0
$bridge = $env:CLIPD_TEST_BRIDGE -eq '1'
if ($bridge) { "NOTE clip-win-bridge is running: it re-sets earlier copies, so per-copy checks accept >= 1 entry" }
function Check($name, $ok, $detail = '') {
  if ($ok) { "PASS $name" } else { "FAIL $name $detail"; $script:fail++ }
}
function Zero { New-Object IO.MemoryStream(,[byte[]](0,0,0,0)) }
function Tagged($o, [switch]$Exclude) {
  $o.SetData('CanIncludeInClipboardHistory', (Zero))
  $o.SetData('CanUploadToCloudClipboard', (Zero))
  if ($Exclude) { $o.SetData('ExcludeClipboardContentFromMonitorProcessing', (Zero)) }
  [Windows.Forms.Clipboard]::SetDataObject($o, $true, 20, 50)
}
function Copy-Text($s, [switch]$Exclude) {
  $o = New-Object Windows.Forms.DataObject
  $o.SetData([Windows.Forms.DataFormats]::UnicodeText, $s)
  Tagged $o -Exclude:$Exclude
}
function Entries { @(Get-ChildItem "$dir\folder" -Filter '*.age' | Where-Object Name -notlike 'hb-*').Count }
function Wait-Entries($n, $ms = 4000) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  while ((Entries) -lt $n -and $t.ElapsedMilliseconds -lt $ms) { Start-Sleep -Milliseconds 50 }
  Start-Sleep -Milliseconds 400   # let any extra (wrong) entry land too
  Entries
}
# Entries (as the viewer sees them) whose preview is exactly $text.
function Count-Preview($text) { @(Viewer list | Where-Object { ($_ -split "`t", 4)[3] -ceq $text }).Count }
function Once($n) { if ($bridge) { $n -ge 1 } else { $n -eq 1 } }
# A second device view of the same folder: our agent's entries are remote to it.
function Viewer { $env:CLIPD_DEVICE = 'viewer'; try { & $exe @args } finally { $env:CLIPD_DEVICE = 'wintest' } }

# --- snapshot the user's clipboard, in memory only ---
$saved = New-Object Windows.Forms.DataObject
$savedAny = $false
$orig = [Windows.Forms.Clipboard]::GetDataObject()
if ($orig) {
  foreach ($f in $orig.GetFormats($false)) {
    try { $d = $orig.GetData($f, $false); if ($null -ne $d) { $saved.SetData($f, $false, $d); $savedAny = $true } } catch {}
  }
}

$agent = $null
try {
  & $exe keygen | Out-Null
  Copy-Text 'clipd-test: before agent start'   # pre-existing copy: must not be published
  $agent = Start-Process -FilePath $exe -ArgumentList 'agent','windows' -PassThru -WindowStyle Hidden `
    -RedirectStandardError "$dir\agent.log" -RedirectStandardOutput "$dir\agent.out"
  Set-Content "$dir\agent.pid" $agent.Id
  $t = [Diagnostics.Stopwatch]::StartNew()
  while (-not ((Test-Path "$dir\agent.log") -and (Select-String -Quiet 'listening' "$dir\agent.log")) -and $t.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
  Check 'agent registers listener' (Select-String -Quiet 'listening' "$dir\agent.log")
  Start-Sleep -Milliseconds 300
  Check 'pre-existing copy not published' ((Entries) -eq 0)

  $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $plain = "clipd-test plain $tag ž€"
  Copy-Text $plain
  $n = Wait-Entries 1
  $c = Count-Preview $plain
  Check 'plain copy -> 1 entry' ((Once $c) -and (Once $n)) "matching $c, total $n"
  $plainId = ((Viewer list | Where-Object { ($_ -split "`t", 4)[3] -ceq $plain } | Select-Object -Last 1) -split "`t")[0]
  Check 'viewer lists it as origin wintest' ((Viewer list) -match "^$plainId`twintest`t") "id $plainId"

  $secret = "clipd-test secret $tag"
  Copy-Text $secret -Exclude
  Start-Sleep -Milliseconds 1500
  $leak = @(Viewer list | Where-Object { $_.Contains("secret $tag") }).Count
  Check 'excluded copy -> 0 entries' ($leak -eq 0) "entries holding it: $leak"

  $burst = 1..5 | ForEach-Object { "clipd-test burst $tag #$_" }
  foreach ($s in $burst) { Copy-Text $s; Start-Sleep -Milliseconds 250 }
  $null = Wait-Entries ($n + 5)
  $counts = $burst | ForEach-Object { Count-Preview $_ }
  Check '5-copy burst -> 5 entries' (@($counts | Where-Object { -not (Once $_) }).Count -eq 0) "per copy: $($counts -join ',')"

  $bmp = New-Object Drawing.Bitmap 4, 3
  $bmp.SetPixel(0, 0, [Drawing.Color]::Red)
  $o = New-Object Windows.Forms.DataObject
  $o.SetData([Windows.Forms.DataFormats]::Bitmap, $bmp)
  Tagged $o
  $null = Wait-Entries ((Entries) + 1)
  $c = Count-Preview '[image 4x3]'
  Check 'bitmap copy -> 1 image entry, listed [image 4x3]' ($c -eq 1) "got $c"

  # pick the oldest text entry by id: not the last written, so only the
  # echo guard can stop the agent re-sending it
  $null = Viewer list
  $c0 = Count-Preview $plain
  Viewer pick $plainId
  $rc = $LASTEXITCODE
  Check 'pick <id> exit 0' ($rc -eq 0) "rc $rc"
  Check 'pick text matches' ([Windows.Forms.Clipboard]::GetText() -ceq $plain)
  $d = [Windows.Forms.Clipboard]::GetDataObject()
  $fmts = $d.GetFormats($false)
  foreach ($f in 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
    $v = $d.GetData($f)
    $bytes = if ($v -is [IO.MemoryStream]) { $v.ToArray() } else { @() }
    Check "pick sets $f=0" (($fmts -contains $f) -and $bytes.Length -eq 4 -and ($bytes | Measure-Object -Sum).Sum -eq 0) "formats: $($fmts -join ',')"
  }
  # Count copies of the picked content, not all entries: another watcher
  # on this host (clip-win-bridge) may legitimately re-set older text.
  Start-Sleep -Milliseconds 1500
  $hits = Count-Preview $plain
  Check 'agent does not re-send the pick' ($hits -eq $c0) "copies of picked text: $hits, before pick: $c0"

  $imgId = ((Viewer list | Where-Object { ($_ -split "`t", 4)[3] -ceq '[image 4x3]' }) -split "`t")[0]
  Viewer pick $imgId
  $rc = $LASTEXITCODE
  $d = [Windows.Forms.Clipboard]::GetDataObject()
  Check 'pick of image sets PNG + DIB' (($rc -eq 0) -and ($d.GetFormats($false) -contains 'PNG') -and $d.GetDataPresent([Windows.Forms.DataFormats]::Dib)) "rc $rc formats: $($d.GetFormats($false) -join ',')"
  Start-Sleep -Milliseconds 1500
  $hits = Count-Preview '[image 4x3]'
  Check 'agent does not re-send the image pick' ($hits -eq 1) "image entries: $hits"

  # --latest = the top row of `list` (newest remote entry)
  $top = (Viewer list | Select-Object -First 1) -split "`t", 4
  Viewer pick --latest
  $rc = $LASTEXITCODE
  $d = [Windows.Forms.Clipboard]::GetDataObject()
  $ok = if ($top[3] -ceq '[image 4x3]') { $d.GetFormats($false) -contains 'PNG' } else { [Windows.Forms.Clipboard]::GetText() -ceq $top[3] }
  Check 'pick --latest publishes the newest remote entry' (($rc -eq 0) -and $ok) "rc $rc top $($top[0])"

  Viewer pick ffffffffffffffff
  $rc = $LASTEXITCODE
  Check 'pick unknown id exit 1' ($rc -eq 1) "rc $rc"

  $log = Get-Content -Raw "$dir\agent.log"
  Check 'agent log has no payload' (-not ($log.Contains($tag)))
  Check 'agent log records excluded' ($log -match 'excluded')
} catch {
  "FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $script:fail++
} finally {
  if ($agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue; $agent.WaitForExit(5000) | Out-Null; Remove-Item "$dir\agent.pid" -ErrorAction SilentlyContinue }
  if ($savedAny) { [Windows.Forms.Clipboard]::SetDataObject($saved, $true, 20, 50) } else { [Windows.Forms.Clipboard]::Clear() }
  "clipboard restored ($(if ($savedAny) {'snapshot'} else {'was empty'}))"
}
if ($script:fail -gt 0) { "--- agent.log ---"; Get-Content "$dir\agent.log" }
exit $script:fail
PS1

rc=0
WSLENV="${WSLENV:+$WSLENV:}CLIPD_TEST_BRIDGE" CLIPD_TEST_BRIDGE=$bridge psh -STA -ExecutionPolicy Bypass -File "$windir\\t.ps1" || rc=$?
if [ "$rc" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $rc check(s)"; fi
exit "$rc"
