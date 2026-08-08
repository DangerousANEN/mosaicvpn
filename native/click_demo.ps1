Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Mouse {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, uint dwExtraInfo);
    public const uint LEFTDOWN = 0x02, LEFTUP = 0x04;
}
"@

function Click-At($x, $y, $delay=500) {
    [Mouse]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200
    [Mouse]::mouse_event([Mouse]::LEFTDOWN, 0, 0, 0, 0)
    [Mouse]::mouse_event([Mouse]::LEFTUP, 0, 0, 0, 0)
    Start-Sleep -Milliseconds $delay
}

# Window is at 0,0, 1116x759
# Header: 0-50px, Status: 50-78px, Content: 78-759px
# Variant buttons in header at y~35:
# V1: ~790, V2: ~870, V3: ~950, V4: ~1030

Write-Host "V1: Server List - waiting 4s"
Start-Sleep -Seconds 4

Write-Host "Clicking V2"
Click-At 870 35 800
Start-Sleep -Seconds 3

Write-Host "V2: Card Carousel - clicking arrows"
# Right arrow approx at center-bottom area
Click-At 580 480 800  # right arrow
Click-At 580 480 800  # right arrow
Click-At 580 480 800  # right arrow

Write-Host "Clicking Connect on card"
Click-At 450 430 800  # connect button
Start-Sleep -Seconds 2

Write-Host "Clicking V3"
Click-At 950 35 800
Start-Sleep -Seconds 3

Write-Host "V3: Dashboard - clicking servers on right"
Click-At 700 200 800  # server
Click-At 700 280 800  # server
Click-At 700 350 800  # server

Write-Host "Clicking Connect (dashboard)"
Click-At 160 520 800  # connect
Start-Sleep -Seconds 2

Write-Host "Clicking V4"
Click-At 1030 35 800
Start-Sleep -Seconds 3

Write-Host "V4: Country Grid - clicking servers"
Click-At 200 300 800  # server
Click-At 200 350 800  # server

Write-Host "Clicking Go button"
Click-At 950 340 800  # go
Start-Sleep -Seconds 2

Write-Host "Back to V1"
Click-At 790 35 800
Start-Sleep -Seconds 3

Write-Host "V1: Clicking Connect on a server"
Click-At 950 200 800  # connect button
Start-Sleep -Seconds 2

Write-Host "Done with demo sequence"
