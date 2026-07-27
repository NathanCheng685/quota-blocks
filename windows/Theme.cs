using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace QuotaBlocks;

/// <summary>Colours that track the Windows taskbar's light/dark setting.</summary>
public sealed record Theme(
    Color Surface,
    Color Border,
    Color Text,
    Color SecondaryText,
    Color EmptyBlock,
    Color Hover,
    Color Divider)
{
    public static readonly Color CodexGreen = Color.FromArgb(0x10, 0xA3, 0x7F);
    public static readonly Color ClaudeClay = Color.FromArgb(0xD9, 0x77, 0x57);

    private static readonly Theme Dark = new(
        Surface: Color.FromArgb(250, 38, 38, 40),
        Border: Color.FromArgb(38, 255, 255, 255),
        Text: Color.FromArgb(245, 245, 247),
        SecondaryText: Color.FromArgb(165, 165, 172),
        // Sitting directly on the taskbar rather than on a panel, an empty block
        // needs enough contrast to still read as one of the five slots.
        EmptyBlock: Color.FromArgb(74, 255, 255, 255),
        Hover: Color.FromArgb(26, 255, 255, 255),
        Divider: Color.FromArgb(30, 255, 255, 255));

    private static readonly Theme Light = new(
        Surface: Color.FromArgb(250, 250, 250, 252),
        Border: Color.FromArgb(36, 0, 0, 0),
        Text: Color.FromArgb(24, 24, 27),
        SecondaryText: Color.FromArgb(110, 110, 118),
        EmptyBlock: Color.FromArgb(58, 0, 0, 0),
        Hover: Color.FromArgb(18, 0, 0, 0),
        Divider: Color.FromArgb(26, 0, 0, 0));

    public static Theme Current => UsesLightTheme() ? Light : Dark;

    public static Color Provider(QuotaProvider provider) =>
        provider == QuotaProvider.Codex ? CodexGreen : ClaudeClay;

    private static bool UsesLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
        catch (Exception e) when (e is IOException or System.Security.SecurityException)
        {
            return false;
        }
    }
}

public static class DrawingExtensions
{
    public static GraphicsPath RoundedRect(RectangleF bounds, float radius)
    {
        var path = new GraphicsPath();
        radius = Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2f);
        if (radius <= 0.5f)
        {
            path.AddRectangle(bounds);
            return path;
        }

        var diameter = radius * 2;
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void FillRounded(this Graphics g, RectangleF bounds, float radius, Color color)
    {
        using var path = RoundedRect(bounds, radius);
        using var brush = new SolidBrush(color);
        g.FillPath(brush, path);
    }

    public static void DrawRounded(this Graphics g, RectangleF bounds, float radius, Color color, float width)
    {
        using var path = RoundedRect(bounds, radius);
        using var pen = new Pen(color, width);
        g.DrawPath(pen, path);
    }
}
