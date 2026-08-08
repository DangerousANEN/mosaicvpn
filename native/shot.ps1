Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Find and focus mosaicvpn window
$procs = Get-Process -Name "mosaicvpn" -ErrorAction SilentlyContinue
if ($procs) {
    $hwnd = $procs[0].MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinFuncs {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
        [WinFuncs]::ShowWindow($hwnd, 9) | Out-Null
        Start-Sleep -Milliseconds 500
        [WinFuncs]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 1500

        $rect = New-Object WinFuncs+RECT
        [WinFuncs]::GetWindowRect($hwnd, [ref]$rect)
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        if ($w -gt 0 -and $h -gt 0) {
            $bmp = New-Object System.Drawing.Bitmap($w, $h)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
            $out = "C:\Users\ANEN\mosaicvpn\native\screen_atlas.png"
            $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
            Write-Output "OK: $out ${w}x${h}"
        } else {
            Write-Output "ERR: window rect is ${w}x${h}"
        }
    } else {
        Write-Output "ERR: MainWindowHandle is zero"
    }
} else {
    Write-Output "ERR: mosaicvpn process not found"
}
