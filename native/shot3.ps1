Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;

public class Win2 {
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

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static void Capture(string title, string path) {
        IntPtr hwnd = FindWindow(null, title);
        if (hwnd == IntPtr.Zero) { Console.WriteLine("ERR: Window not found: " + title); return; }

        ShowWindow(hwnd, 9); // SW_RESTORE
        System.Threading.Thread.Sleep(500);
        SetForegroundWindow(hwnd);
        System.Threading.Thread.Sleep(500);

        // Force window to a known size/position
        MoveWindow(hwnd, 100, 100, 1100, 700, true);
        System.Threading.Thread.Sleep(500);

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

[Win2]::Capture("MosaicVPN Atlas", "C:\Users\ANEN\mosaicvpn\native\screen_atlas.png")
