# Take screenshot of mosaicvpn.exe window
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
public class Win {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@

# Find the window — Slint window title is "MosaicVPN"
$hwnd = [Win]::FindWindow($null, "MosaicVPN")
if ($hwnd -eq [IntPtr]::Zero) {
    # Try alternative titles
    $hwnd = [Win]::FindWindow($null, "Mosaic VPN")
}
if ($hwnd -eq [IntPtr]::Zero) {
    # Try by class name for Slint windows
    $hwnd = [Win]::FindWindow("Slint Window", $null)
}

if ($hwnd -ne [IntPtr]::Zero) {
    [Win]::ShowWindow($hwnd, 9)  # SW_RESTORE
    Start-Sleep -Milliseconds 500
    [Win]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 1000

    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$rect)
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
    $out = "C:\Users\ANEN\mosaicvpn\native\screenshot_new.png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Write-Output "Saved $out (${w}x${h})"
} else {
    # Fallback: capture full primary screen
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $out = "C:\Users\ANEN\mosaicvpn\native\screenshot_new.png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Write-Output "Window not found. Full screen saved to $out"
}
