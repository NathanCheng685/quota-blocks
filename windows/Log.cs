using System.Diagnostics;

namespace QuotaBlocks;

/// <summary>
/// Opt-in trace file for a GUI app that has nowhere to print. Enabled by
/// setting QUOTABLOCKS_LOG=1; writes next to the executable.
/// </summary>
public static class Log
{
    private static readonly bool Enabled =
        Environment.GetEnvironmentVariable("QUOTABLOCKS_LOG") is "1" or "true";

    private static readonly string Path = System.IO.Path.Combine(
        System.IO.Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "quota-blocks.log");

    private static readonly object Gate = new();

    public static void Write(string message)
    {
        if (!Enabled) return;
        try
        {
            lock (Gate)
            {
                File.AppendAllText(Path, $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch (IOException)
        {
        }
    }

    [Conditional("DEBUG")]
    public static void Debug(string message) => Write(message);
}
