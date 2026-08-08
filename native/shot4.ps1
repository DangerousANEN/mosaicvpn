Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;

public class Win3 {
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static void Capture(string title, string path) {
        // Try multiple times to find the window
        IntPtr hwnd = IntPtr.Zero;
        for (int i = 0; i < 10; i++) {
            hwnd = FindWindow(null, title);
            if (hwnd != IntPtr.Zero) break;
            Thread.Sleep(500);
        }
        if (hwnd == IntPtr.Zero) { Console.WriteLine("ERR: Window not found: " + title); return; }

        // Restore if minimized
        if (IsIconic(hwnd)) {
            ShowWindow(hwnd, 9); // SW_RESTORE
            Thread.Sleep(500);
        }

        // Move to known position and size
        MoveWindow(hwnd, 50, 50, 1100, 700, true);
        Thread.Sleep(800);

        // Force foreground
        SetForegroundWindow(hwnd);
        Thread.Sleep(800);

        RECT r;
        GetWindowRect(hwnd, out r);
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w < 50 || h < 50) { Console.WriteLine("ERR: Window too small: " + w + "x" + h); return; }

        Bitmap bmp = new Bitmap(w, h);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
        }
        bmp.Save(path, ImageFormat.Png);
        Console.WriteLine("OK: " + path + " " + w + "x" + h);
    }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing

[Win3]::Capture("MosaicVPN Atlas", "C:\Users\ANEN\mosaicvpn\native\screen_atlas.png")
