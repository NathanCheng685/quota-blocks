using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace QuotaBlocks;

/// <summary>
/// A borderless window drawn from a 32-bit ARGB bitmap via UpdateLayeredWindow.
/// Per-pixel alpha is what makes the rounded corners land cleanly on top of the
/// taskbar instead of showing a jagged region edge.
/// </summary>
public abstract class LayeredForm : Form
{
    protected LayeredForm(bool clickThroughFocus)
    {
        NoActivate = clickThroughFocus;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
    }

    private bool NoActivate { get; }

    protected override bool ShowWithoutActivation => NoActivate;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // WS_EX_TOPMOST is applied at creation rather than through Form.TopMost:
            // WinForms drops it again whenever it re-applies bounds on a layered window.
            cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
            if (NoActivate) cp.ExStyle |= Native.WS_EX_NOACTIVATE;
            return cp;
        }
    }

    /// <summary>
    /// A non-activating window is not the foreground window, so WinForms answers
    /// WM_MOUSEACTIVATE in a way that swallows the click that would have
    /// activated it — the bar would simply stop responding whenever another app
    /// held the foreground. MA_NOACTIVATE delivers the click without focus.
    /// </summary>
    protected override void WndProc(ref Message m)
    {
        const int WM_MOUSEACTIVATE = 0x0021;
        const int MA_NOACTIVATE = 3;

        if (NoActivate && m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = MA_NOACTIVATE;
            return;
        }

        base.WndProc(ref m);
    }

    /// <summary>Renders the window contents; size is in physical pixels.</summary>
    protected abstract void Render(Graphics g, Size size);

    protected abstract Size MeasureContent();

    public void Redraw()
    {
        var size = MeasureContent();
        if (size.Width <= 0 || size.Height <= 0) return;

        using var bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.Clear(Color.Transparent);
            Render(g, size);
        }

        Premultiply(bitmap);
        ApplyBitmap(bitmap);
    }

    /// <summary>
    /// UpdateLayeredWindow's AC_SRC_ALPHA expects premultiplied colour channels,
    /// but GDI+ hands back straight alpha. Without this, anything lighter than
    /// its own alpha — the whole light theme — composites blown out.
    /// </summary>
    private static void Premultiply(Bitmap bitmap)
    {
        var rect = new Rectangle(Point.Empty, bitmap.Size);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var length = Math.Abs(data.Stride) * data.Height;
            var pixels = new byte[length];
            Marshal.Copy(data.Scan0, pixels, 0, length);

            for (var i = 0; i < length; i += 4)
            {
                int alpha = pixels[i + 3];
                if (alpha == 255) continue;
                if (alpha == 0)
                {
                    pixels[i] = pixels[i + 1] = pixels[i + 2] = 0;
                    continue;
                }
                pixels[i] = (byte)(pixels[i] * alpha / 255);
                pixels[i + 1] = (byte)(pixels[i + 1] * alpha / 255);
                pixels[i + 2] = (byte)(pixels[i + 2] * alpha / 255);
            }

            Marshal.Copy(pixels, 0, data.Scan0, length);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    private void ApplyBitmap(Bitmap bitmap)
    {
        var screenDc = Native.GetDC(IntPtr.Zero);
        var memoryDc = Native.CreateCompatibleDC(screenDc);
        var hBitmap = IntPtr.Zero;
        var oldBitmap = IntPtr.Zero;

        try
        {
            hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
            oldBitmap = Native.SelectObject(memoryDc, hBitmap);

            var size = new Native.SIZE(bitmap.Width, bitmap.Height);
            var source = new Native.POINT(0, 0);
            var destination = new Native.POINT(Left, Top);
            var blend = new Native.BLENDFUNCTION
            {
                BlendOp = Native.AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = Native.AC_SRC_ALPHA,
            };

            var updated = Native.UpdateLayeredWindow(
                Handle, screenDc, ref destination, ref size, memoryDc, ref source, 0, ref blend, Native.ULW_ALPHA);
            Log.Write(
                $"{GetType().Name} UpdateLayeredWindow={updated} err={Marshal.GetLastWin32Error()} " +
                $"at ({destination.X},{destination.Y}) {bitmap.Width}x{bitmap.Height} " +
                $"dpi={DeviceDpi} exStyle=0x{Native.GetWindowLong(Handle, -20):X8}");

            // Keep the managed Size in sync so Bounds/hit-testing stay correct.
            if (Size != bitmap.Size) Size = bitmap.Size;
        }
        finally
        {
            Native.ReleaseDC(IntPtr.Zero, screenDc);
            if (hBitmap != IntPtr.Zero)
            {
                Native.SelectObject(memoryDc, oldBitmap);
                Native.DeleteObject(hBitmap);
            }
            Native.DeleteDC(memoryDc);
        }
    }

    /// <summary>
    /// Takes the foreground even though this process does not own it. A plain
    /// SetForegroundWindow is refused in that situation; attaching to the current
    /// foreground thread's input queue first makes the call legal. Without this
    /// the panel never really activates, so it never gets the Deactivate that
    /// dismisses it when the user clicks elsewhere.
    /// </summary>
    protected void TakeForeground()
    {
        var foreground = Native.GetForegroundWindow();
        if (foreground == Handle) return;

        var thisThread = Native.GetCurrentThreadId();
        var foregroundThread = Native.GetWindowThreadProcessId(foreground, out _);

        if (foregroundThread == 0 || foregroundThread == thisThread)
        {
            Native.SetForegroundWindow(Handle);
            return;
        }

        Native.AttachThreadInput(thisThread, foregroundThread, true);
        try
        {
            Native.SetForegroundWindow(Handle);
        }
        finally
        {
            Native.AttachThreadInput(thisThread, foregroundThread, false);
        }
    }

    /// <summary>Re-asserts topmost so newly launched topmost windows do not bury the bar.</summary>
    public void BringToFront(bool activate = false)
    {
        var flags = Native.SWP_NOMOVE | Native.SWP_NOSIZE | (activate ? 0 : Native.SWP_NOACTIVATE);
        Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, flags);
    }
}

internal static class Native
{
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOPMOST = 0x00000008;

    public const int ULW_ALPHA = 0x00000002;
    public const byte AC_SRC_OVER = 0x00;
    public const byte AC_SRC_ALPHA = 0x01;

    public const int SWP_NOSIZE = 0x0001;
    public const int SWP_NOMOVE = 0x0002;
    public const int SWP_NOACTIVATE = 0x0010;
    public static readonly IntPtr HWND_TOPMOST = new(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT(int x, int y)
    {
        public int X = x;
        public int Y = y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE(int cx, int cy)
    {
        public int Cx = cx;
        public int Cy = cy;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool UpdateLayeredWindow(
        IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc,
        ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    public static extern int GetWindowLong(IntPtr hWnd, int index);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, int flags);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool AttachThreadInput(uint attachTo, uint attachFrom, bool attach);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    public static extern uint GetCurrentThreadId();

    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000;

    public delegate void WinEventProc(
        IntPtr hook, uint eventType, IntPtr hwnd, int objectId, int childId, uint thread, uint time);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr module, WinEventProc callback,
        uint processId, uint threadId, uint flags);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool UnhookWinEvent(IntPtr hook);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int capacity);

    [DllImport("user32.dll", EntryPoint = "FindWindowW", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string? className, string? windowName);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public const int WH_MOUSE_LL = 14;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_MBUTTONDOWN = 0x0207;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int hookId, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? name);

    /// <summary>
    /// Where the taskbar actually is right now, or an empty rectangle when there
    /// is none. Read from the window itself rather than from the working area,
    /// because an auto-hidden taskbar slides off-screen without ever giving the
    /// working area back.
    /// </summary>
    public static Rectangle TaskbarBounds()
    {
        var tray = FindWindow("Shell_TrayWnd", null);
        if (tray == IntPtr.Zero || !IsWindowVisible(tray)) return Rectangle.Empty;
        if (!GetWindowRect(tray, out var rect)) return Rectangle.Empty;
        return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
    }

    public static IntPtr TaskbarWindow() => FindWindow("Shell_TrayWnd", null);

    /// <summary>
    /// True when the window spans the whole monitor. The shell's own windows are
    /// excluded: the desktop and the taskbar are always screen-sized and must not
    /// be mistaken for a fullscreen app.
    /// </summary>
    public static bool CoversScreen(IntPtr hWnd, Rectangle screen)
    {
        if (hWnd == IntPtr.Zero) return false;

        var name = new System.Text.StringBuilder(256);
        GetClassName(hWnd, name, name.Capacity);
        switch (name.ToString())
        {
            case "Shell_TrayWnd":
            case "Shell_SecondaryTrayWnd":
            case "Progman":
            case "WorkerW":
            case "Windows.UI.Core.CoreWindow":
                return false;
        }

        return GetWindowRect(hWnd, out var rect)
            && rect.Left <= screen.Left
            && rect.Top <= screen.Top
            && rect.Right >= screen.Right
            && rect.Bottom >= screen.Bottom;
    }

    [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll", ExactSpelling = true)]
    public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

    [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool DeleteObject(IntPtr hObject);
}
