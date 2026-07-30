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
        Append(message);
    }

    /// <summary>
    /// Always written, whether tracing is enabled or not. A failure the user did
    /// not opt into logging is exactly the one worth having a record of.
    /// </summary>
    public static void Error(string message) => Append($"ERROR {message}");

    private static void Append(string message)
    {
        try
        {
            lock (Gate)
            {
                File.AppendAllText(Path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // Deliberately total: this is called from inside native callbacks
            // where a throw would terminate the process, so the logger itself
            // must never be the thing that fails.
        }
    }

    [Conditional("DEBUG")]
    public static void Debug(string message) => Write(message);
}
