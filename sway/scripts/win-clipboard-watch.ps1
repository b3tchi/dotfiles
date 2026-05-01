# win-clipboard-watch.ps1 — Long-running Windows clipboard poller
# Started by sway via win-clipboard-sync. Polls GetClipboardSequenceNumber()
# every 500ms and emits TEXT:<base64>/IMAGE:<base64> on change, one per line.
# Echo-loop prevention is on the Linux side (see win-clipboard-sync.nu).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$seqDef = @"
[DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
"@
Add-Type -NameSpace WinApi -Name ClipboardSeq -MemberDefinition $seqDef

# Force unbuffered stdout so each emission reaches the Linux reader immediately.
[Console]::Out.AutoFlush = $true

# Start at 0 so the current clipboard content is emitted on first tick
# (otherwise a restart silently drops whatever is already on the clipboard).
$last = 0
while ($true) {
    $seq = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()
    if ($seq -ne $last) {
        $emitted = $false
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                if ($img -ne $null) {
                    $ms = New-Object System.IO.MemoryStream
                    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                    Write-Output ("IMAGE:" + [Convert]::ToBase64String($ms.ToArray()))
                    [Console]::Out.Flush()
                    $ms.Dispose(); $img.Dispose()
                    $emitted = $true
                }
            } elseif ([System.Windows.Forms.Clipboard]::ContainsText()) {
                $t = [System.Windows.Forms.Clipboard]::GetText()
                Write-Output ("TEXT:" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)))
                [Console]::Out.Flush()
                $emitted = $true
            } else {
                # Clipboard has something else (files, html, etc.) — accept the
                # seq bump so we don't retry forever.
                $emitted = $true
            }
        } catch {
            # Clipboard locked or transiently unreadable; leave $last unchanged
            # so we retry on the next tick.
        }
        if ($emitted) { $last = $seq }
    }
    Start-Sleep -Milliseconds 500
}
