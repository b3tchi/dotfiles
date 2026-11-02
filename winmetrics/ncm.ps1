# ncm.ps1 - read or write Windows' non-client metrics (kwi3-9mcs), for
# winmetrics/kwi3-titlebar.sh. Windows PowerShell 5.1, no modules.
#
#   ncm.ps1 read
#       One JSON line: the NONCLIENTMETRICSW fields kwi3-titlebar.sh works
#       with (iBorderWidth, iCaptionHeight, lfCaptionFont's lfHeight, face and
#       weight, iPaddedBorderWidth), the system dpi, SM_CYCAPTION and
#       SM_CYSIZEFRAME, the titlebar + top frame of a captioned window
#       ("inset": -top of AdjustWindowRectExForDpi(WS_OVERLAPPEDWINDOW, 96),
#       which equals client top minus the DWM frame top, measured 31 at the
#       defaults and 21 fitted), and the tmHeight GDI gives the caption font's
#       face and weight at lfHeight -6 .. -16 (what Windows' caption floor is
#       made of: iCaptionHeight >= tmHeight + 2). Reads only.
#
#   ncm.ps1 set <border>,<caption>,<padded>,<fontLfHeight>
#       One comma-separated argument ("1,16,0,-11": a bare -11 would be
#       read as a parameter name). SPI_GETNONCLIENTMETRICS, those four fields changed, everything else
#       as it was, SPI_SETNONCLIENTMETRICS with SPIF_UPDATEINIFILE |
#       SPIF_SENDCHANGE: live in every window and kept in the registry
#       (HKCU\Control Panel\Desktop\WindowMetrics). Machine-wide for this user.
#
# NONCLIENTMETRICSW is 504 bytes with iPaddedBorderWidth (Vista+): cbSize 0,
# iBorderWidth 4, iScrollWidth 8, iScrollHeight 12, iCaptionWidth 16,
# iCaptionHeight 20, lfCaptionFont 24 (LOGFONTW, 92 bytes: lfHeight +0,
# lfWeight +16, lfFaceName +28), ..., iPaddedBorderWidth 500.
#
# Exit: 0 done; 1 a Windows call failed; 2 usage.
param([string]$verb = '', [string]$list = '')
$ErrorActionPreference = 'Stop'

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Kwi3Ncm {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfoW(uint a, uint b, byte[] p, uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool AdjustWindowRectExForDpi(ref RECT r, uint style, bool menu, uint ex, uint dpi);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("gdi32.dll")] public static extern IntPtr CreateFontIndirectW(byte[] lf);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr h);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr h, IntPtr o);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr h);
  [DllImport("gdi32.dll")] public static extern bool GetTextMetricsW(IntPtr h, byte[] tm);
}
"@

$SIZE = 504
function Get-Ncm {
    $b = New-Object byte[] $SIZE
    [BitConverter]::GetBytes([int]$SIZE).CopyTo($b, 0)
    if (-not [Kwi3Ncm]::SystemParametersInfoW(0x29, $SIZE, $b, 0)) {
        [Console]::Error.WriteLine("ncm.ps1: SPI_GETNONCLIENTMETRICS failed"); exit 1
    }
    return ,$b
}
function I32($b, $o) { [BitConverter]::ToInt32($b, $o) }

switch ($verb) {
    'read' {
        $b = Get-Ncm
        $face = [Text.Encoding]::Unicode.GetString($b, 24 + 28, 64).Split([char]0)[0]
        $r = New-Object Kwi3Ncm+RECT
        [void][Kwi3Ncm]::AdjustWindowRectExForDpi([ref]$r, 0x00CF0000, $false, 0, 96)
        $fonts = @()
        $dc = [Kwi3Ncm]::CreateCompatibleDC([IntPtr]::Zero)
        foreach ($h in -6..-16) {
            $lf = New-Object byte[] 92
            [Array]::Copy($b, 24, $lf, 0, 92)
            [BitConverter]::GetBytes([int]$h).CopyTo($lf, 0)
            $f = [Kwi3Ncm]::CreateFontIndirectW($lf)
            $old = [Kwi3Ncm]::SelectObject($dc, $f)
            $tm = New-Object byte[] 64
            if ([Kwi3Ncm]::GetTextMetricsW($dc, $tm)) { $fonts += @{ lf = $h; tm = (I32 $tm 0) } }
            [void][Kwi3Ncm]::SelectObject($dc, $old)
            [void][Kwi3Ncm]::DeleteObject($f)
        }
        [void][Kwi3Ncm]::DeleteDC($dc)
        $o = [ordered]@{
            dpi = [int][Kwi3Ncm]::GetDpiForSystem()
            border = I32 $b 4
            caption = I32 $b 20
            padded = I32 $b 500
            font = I32 $b 24
            face = $face
            weight = I32 $b 40
            smCyCaption = [Kwi3Ncm]::GetSystemMetrics(4)
            smCySizeFrame = [Kwi3Ncm]::GetSystemMetrics(33)
            inset = -$r.t
            fonts = $fonts
        }
        [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 3))
        exit 0
    }
    'set' {
        $values = @($list.Split(',') | Where-Object { $_ -match '^-?[0-9]+$' } | ForEach-Object { [int]$_ })
        if ($values.Count -ne 4 -or $list.Split(',').Count -ne 4) {
            [Console]::Error.WriteLine("usage: ncm.ps1 set <border>,<caption>,<padded>,<fontLfHeight>"); exit 2
        }
        $b = Get-Ncm
        [BitConverter]::GetBytes([int]$values[0]).CopyTo($b, 4)
        [BitConverter]::GetBytes([int]$values[1]).CopyTo($b, 20)
        [BitConverter]::GetBytes([int]$values[2]).CopyTo($b, 500)
        [BitConverter]::GetBytes([int]$values[3]).CopyTo($b, 24)
        # SPIF_UPDATEINIFILE (1) | SPIF_SENDCHANGE (2)
        if (-not [Kwi3Ncm]::SystemParametersInfoW(0x2A, $SIZE, $b, 3)) {
            [Console]::Error.WriteLine("ncm.ps1: SPI_SETNONCLIENTMETRICS failed"); exit 1
        }
        exit 0
    }
    default { [Console]::Error.WriteLine("usage: ncm.ps1 read | set <border>,<caption>,<padded>,<fontLfHeight>"); exit 2 }
}
