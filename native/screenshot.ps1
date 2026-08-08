Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

$procs = Get-Process -Name mosaicvpn -ErrorAction SilentlyContinue
if ($procs -and $procs.MainWindowHandle -ne [IntPtr]::Zero) {
    [Win32]::ShowWindow($procs.MainWindowHandle, 9)  # SW_RESTORE
    Start-Sleep -Milliseconds 200
    [Win32]::SetForegroundWindow($procs.MainWindowHandle)
    Start-Sleep -Milliseconds 500
}

$bmp = New-Object System.Drawing.Bitmap(1280, 720)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
$bmp.Save('C:\Users\ANEN\mosaicvpn\native\screenshot9.png')
$g.Dispose()
$bmp.Dispose()
Write-Output "done"
