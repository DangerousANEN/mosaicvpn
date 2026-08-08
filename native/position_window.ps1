Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool r);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# Get the process with "UI Concepts" in title
$procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*UI Concepts*" }
if ($procs.Count -gt 0) {
    $proc = $procs[0]
    $hwnd = $proc.MainWindowHandle
    Write-Host "Found: $($proc.MainWindowTitle) HWND=$hwnd"
    [Win32]::MoveWindow($hwnd, 0, 0, 1116, 759, $true)
    [Win32]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 500
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($hwnd, [ref]$rect)
    Write-Host "Window at: L=$($rect.Left) T=$($rect.Top) R=$($rect.Right) B=$($rect.Bottom)"
    Write-Host "Size: $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top)"
} else {
    Write-Host "No process found with 'UI Concepts' in title"
}
