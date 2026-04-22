# win-clipboard-watch.ps1 — Long-running Windows clipboard poller
# Started by sway via win-clipboard-sync. Polls GetClipboardSequenceNumber()
# every 500ms and emits TEXT:<base64>/IMAGE:<base64> on change, one per line.
# Echo-loop prevention happens on the Linux side via timestamp sentinel files.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$seqDef = @"
[DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
"@
Add-Type -NameSpace WinApi -Name ClipboardSeq -MemberDefinition $seqDef

$last = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()
while ($true) {
    Start-Sleep -Milliseconds 500
    $seq = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()
    if ($seq -eq $last) { continue }
    $last = $seq
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Forms.Clipboard]::GetImage()
            if ($img -ne $null) {
                $ms = New-Object System.IO.MemoryStream
                $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Output ("IMAGE:" + [Convert]::ToBase64String($ms.ToArray()))
                [Console]::Out.Flush()
                $ms.Dispose(); $img.Dispose()
            }
        } elseif ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $t = [System.Windows.Forms.Clipboard]::GetText()
            Write-Output ("TEXT:" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)))
            [Console]::Out.Flush()
        }
    } catch {
        # Clipboard briefly locked by another process; next poll will retry
    }
}
