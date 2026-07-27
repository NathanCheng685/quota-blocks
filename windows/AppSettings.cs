using Microsoft.Win32;

namespace QuotaBlocks;

public enum AppLanguage
{
    Chinese,
    English,
}

/// <summary>Preferences live under HKCU so no config file has to be shipped or migrated.</summary>
public static class AppSettings
{
    private const string SettingsKey = @"Software\QuotaBlocks";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "QuotaBlocks";

    public static AppLanguage Language
    {
        get
        {
            var saved = Read("Language");
            if (saved == "english") return AppLanguage.English;
            if (saved == "chinese") return AppLanguage.Chinese;
            return System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh"
                ? AppLanguage.Chinese
                : AppLanguage.English;
        }
        set => Write("Language", value == AppLanguage.English ? "english" : "chinese");
    }

    public static bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string path && path.Contains("QuotaBlocks", StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return;
            if (value)
            {
                var exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe)) key.SetValue(RunValue, $"\"{exe}\"");
            }
            else
            {
                key.DeleteValue(RunValue, throwOnMissingValue: false);
            }
        }
    }

    private static string? Read(string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(SettingsKey);
        return key?.GetValue(name) as string;
    }

    private static void Write(string name, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(SettingsKey);
        key?.SetValue(name, value);
    }
}
