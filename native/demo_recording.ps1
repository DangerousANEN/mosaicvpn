# demo_recording.ps1
# Launches mosaicvpn-demo, records screen with ffmpeg,
# clicks through 4 UI variants, saves mp4

param(
    [string]$ExePath = "C:\Users\ANEN\mosaicvpn\native\target\release\mosaicvpn-demo.exe",
    [string]$OutputDir = "C:\Users\ANEN\mosaicvpn\native"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool repaint);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# Kill any existing instances
Get-Process -Name "mosaicvpn-demo" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# Launch demo
$proc = Start-Process -FilePath $ExePath -PassThru
Start-Sleep -Seconds 3

# Find and position window
$hwnd = [Win32]::FindWindow($null, "MosaicVPN · UI Concepts")
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host "Window not found, trying by process..."
    $hwnd = $proc.MainWindowHandle
}

# Move window to top-left, known size (1100x720 + decorations)
[Win32]::MoveWindow($hwnd, 0, 0, 1116, 759, $true)
[Win32]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 500

# Get window rect for cropping
$rect = New-Object Win32+RECT
[Win32]::GetWindowRect($hwnd, [ref]$rect)
Write-Host "Window rect: L=$($rect.Left) T=$($rect.Top) R=$($rect.Right) B=$($rect.Bottom)"
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top

# Start ffmpeg recording (gdigrab)
$ffmpegArgs = "-y -f gdigrab -framerate 15 -offset_x $($rect.Left) -offset_y $($rect.Top) -video_size ${width}x${height} -i desktop -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p `"$OutputDir\demo_recording.mp4`""
$ffmpeg = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -PassThru -WindowStyle Hidden
Write-Host "Recording started..."

# Give it a moment
Start-Sleep -Seconds 2

# Helper: click at coordinates
function Click-At($x, $y) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    Start-Sleep -Milliseconds 200
    # Send mouse click via mouse_event
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Mouse {
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, uint dwExtraInfo);
    public const uint LEFTDOWN = 0x02, LEFTUP = 0x04;
}
"@
    [Mouse]::mouse_event([Mouse]::LEFTDOWN, 0, 0, 0, 0)
    [Mouse]::mouse_event([Mouse]::LEFTUP, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 300
}

# V1 is already showing (active-variant=0)
Write-Host "Showing V1: Server List"
Start-Sleep -Seconds 3

# Click V2 button (approx x=850, y=65 relative to window)
# Window is at 0,0 so absolute coords are same
Click-At 870 65  # V2
Write-Host "Showing V2: Card Carousel"
Start-Sleep -Seconds 3

# Click right arrow to cycle servers
Click-At 560 380  # Right arrow
Start-Sleep -Seconds 1
Click-At 560 380  # Right arrow
Start-Sleep -Seconds 1
Click-At 560 380  # Right arrow
Start-Sleep -Seconds 2

# Click Connect button
Click-At 470 420  # Connect
Start-Sleep -Seconds 2

# Click V3 button
Click-At 950 65  # V3
Write-Host "Showing V3: Dashboard"
Start-Sleep -Seconds 3

# Click a server on the right list
Click-At 700 250  # Server in list
Start-Sleep -Seconds 1
Click-At 700 300  # Another server
Start-Sleep -Seconds 2

# Click Connect
Click-At 200 520  # Connect
Start-Sleep -Seconds 2

# Click V4 button
Click-At 1030 65  # V4
Write-Host "Showing V4: Country Grid"
Start-Sleep -Seconds 3

# Click a server
Click-At 200 300  # Server
Start-Sleep -Seconds 1
Click-At 200 350  # Another
Start-Sleep -Seconds 2

# Click Go button
Click-At 850 320  # Go
Start-Sleep -Seconds 2

# Back to V1
Click-At 790 65  # V1
Start-Sleep -Seconds 2

# Click Connect on a server
Click-At 900 200  # Connect
Start-Sleep -Seconds 2

# Stop recording
Write-Host "Stopping recording..."
$ffmpeg | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host "Done! Video saved to $OutputDir\demo_recording.mp4"
