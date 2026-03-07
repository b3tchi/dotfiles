# clipboard-to-win-image.ps1 — Set Windows clipboard to a PNG image
# Called from clipboard-to-win.nu
# Argument: WSL path to the PNG file (converted to UNC by caller)
param([string]$ImagePath)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (Test-Path $ImagePath) {
    $img = [System.Drawing.Image]::FromFile($ImagePath)
    [System.Windows.Forms.Clipboard]::SetImage($img)
    $img.Dispose()
}
