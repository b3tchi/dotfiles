# win-clipboard-monitor.ps1 — Monitor Windows clipboard for changes
#
# Runs persistently on the Windows side. When the user switches focus
# into the WSLg/wlroots window and the Windows clipboard has changed,
# outputs a line to stdout:
#   TEXT:<base64-encoded-text>
#   IMAGE:<base64-encoded-png>
#
# Based on jordankoehn/sway-wsl2, extended with image support.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class APIFuncs
{
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hwnd, StringBuilder lpString, int cch);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern Int32 GetWindowThreadProcessId(IntPtr hWnd, out Int32 lpdwProcessId);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern Int32 GetWindowTextLength(IntPtr hWnd);
}
"@

$clipSeqDef = @"
[DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
"@
Add-Type -NameSpace WinApi -Name ClipboardSeq -MemberDefinition $clipSeqDef

$inWsl = $true
$lastSequenceNumber = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()

while($true) {
    $w = [apifuncs]::GetForegroundWindow()
    $len = [apifuncs]::GetWindowTextLength($w)
    $sb = New-Object text.stringbuilder -ArgumentList ($len + 1)
    $rtnlen = [apifuncs]::GetWindowText($w, $sb, $sb.Capacity)
    $currWindow = $sb.tostring()

    if ($currWindow -like "*wlroots*") {
        if (!$inWsl) {
            $inWsl = $true
            $newSequenceNumber = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()
            if ($lastSequenceNumber -ne $newSequenceNumber) {
                $lastSequenceNumber = $newSequenceNumber

                # Check for image first, then text
                if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                    $img = [System.Windows.Forms.Clipboard]::GetImage()
                    if ($img -ne $null) {
                        $ms = New-Object System.IO.MemoryStream
                        $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                        $bytes = $ms.ToArray()
                        $encoded = [Convert]::ToBase64String($bytes)
                        Write-Output "IMAGE:$encoded"
                        $ms.Dispose()
                        $img.Dispose()
                    }
                } elseif ([System.Windows.Forms.Clipboard]::ContainsText()) {
                    $clipboard = [System.Windows.Forms.Clipboard]::GetText()
                    $clipboardBytes = [System.Text.Encoding]::UTF8.GetBytes($clipboard)
                    $encoded = [Convert]::ToBase64String($clipboardBytes)
                    Write-Output "TEXT:$encoded"
                }
            }
        }
    } else {
        if ($inWsl) {
            $inWsl = $false
            $lastSequenceNumber = [WinApi.ClipboardSeq]::GetClipboardSequenceNumber()
        }
    }
    Start-Sleep -Milliseconds 200
}
