using System.Globalization;

namespace QuotaBlocks;

/// <summary>Font family picked so CJK glyphs render without falling back to tofu.</summary>
public static class Fonts
{
    public static string Family => AppSettings.Language == AppLanguage.Chinese ? "Microsoft YaHei UI" : "Segoe UI";

    public static Font Ui(float pixelSize, FontStyle style = FontStyle.Regular) =>
        new(Family, pixelSize, style, GraphicsUnit.Pixel);

    /// <summary>Percentages are digits only, so they always use the tighter Segoe face.</summary>
    public static Font Numeric(float pixelSize, FontStyle style = FontStyle.Bold) =>
        new("Segoe UI", pixelSize, style, GraphicsUnit.Pixel);
}

public static class Loc
{
    public static bool IsChinese => AppSettings.Language == AppLanguage.Chinese;

    public static string T(string chinese, string english) => IsChinese ? chinese : english;

    public static string ResetDate(DateTime date)
    {
        var culture = new CultureInfo(IsChinese ? "zh-CN" : "en-US");
        return IsChinese
            ? date.ToString("M月d日 ddd HH:mm", culture)
            : date.ToString("ddd, MMM d, h:mm tt", culture);
    }
}
