using System.Diagnostics;

namespace QuotaBlocks;

/// <summary>
/// Asks Claude Code to refresh its own OAuth credentials when the stored access
/// token has expired.
///
/// Claude Code owns the rotating refresh token; refreshing it from a second
/// process desynchronises the shared credentials and signs Claude Code out.
/// Quota Blocks therefore never calls the OAuth endpoint and never writes
/// credential storage. Instead it runs the user's own <c>claude</c> CLI once
/// with a model name that cannot exist: Claude Code refreshes its expired access
/// token before sending the request, the request itself fails without consuming
/// any quota, and Quota Blocks simply re-reads what Claude Code wrote back.
///
/// Ported from the macOS app's ClaudeCodeRefresh.swift.
/// </summary>
internal static class ClaudeCodeRefresh
{
    /// <summary>
    /// Minimum spacing between attempts, so a genuinely signed-out CLI cannot
    /// make the app spawn <c>claude</c> on every refresh cycle.
    /// </summary>
    private static readonly TimeSpan Cooldown = TimeSpan.FromMinutes(10);

    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(90);

    /// <summary>
    /// Never a real model: the request fails before any tokens are consumed, but
    /// Claude Code still refreshes an expired access token first.
    /// </summary>
    private const string ProbeModel = "quota-blocks-refresh-probe";

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static DateTime lastAttemptUtc = DateTime.MinValue;

    /// <summary>
    /// Returns true when a probe actually ran; the caller re-reads the credential
    /// file afterwards either way.
    /// </summary>
    public static async Task<bool> RequestAsync(CancellationToken cancellationToken)
    {
        if (!await Gate.WaitAsync(TimeSpan.Zero, cancellationToken).ConfigureAwait(false))
        {
            // Another refresh is already in flight; let the caller re-read what
            // it writes rather than queueing a second CLI launch.
            return false;
        }

        try
        {
            if (DateTime.UtcNow - lastAttemptUtc < Cooldown) return false;
            lastAttemptUtc = DateTime.UtcNow;

            return await Task.Run(() => RunProbe(cancellationToken), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Gate.Release();
        }
    }

    private static bool RunProbe(CancellationToken cancellationToken)
    {
        var cli = LocateCli();
        if (cli is null)
        {
            Log.Write("claude CLI not found; cannot refresh");
            return false;
        }

        var info = new ProcessStartInfo(cli)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = ProbeDirectory(),
        };
        // --no-session-persistence and an empty strict MCP config keep the probe
        // from leaving session files behind or starting MCP servers.
        foreach (var argument in new[]
                 {
                     "-p", "--no-session-persistence", "--strict-mcp-config",
                     "--mcp-config", """{"mcpServers":{}}""",
                     "--model", ProbeModel, "ok",
                 })
        {
            info.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(info);
            if (process is null) return false;

            process.StandardInput.Close();
            if (!process.WaitForExit((int)ProbeTimeout.TotalMilliseconds))
            {
                process.Kill(entireProcessTree: true);
                Log.Write("claude refresh probe timed out");
                return false;
            }

            // A non-zero exit is expected and fine: the probe model does not
            // exist. The refresh has already happened by the time it exits.
            Log.Write($"claude refresh probe finished, exit {process.ExitCode}");
            return true;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            Log.Write($"claude refresh probe failed: {e.Message}");
            return false;
        }
    }

    internal static string? LocateCli()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new List<string>
        {
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(home, ".claude", "local", "claude.exe"),
        };
        candidates.AddRange(
            (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(directory => Path.Combine(directory.Trim(), "claude.exe")));

        return candidates.FirstOrDefault(File.Exists);
    }

    /// <summary>
    /// A stable, empty working directory so the probe never picks up project
    /// files and Claude Code records at most one project path for it.
    /// </summary>
    private static string ProbeDirectory()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuotaBlocks", "claude-probe");
        Directory.CreateDirectory(directory);
        return directory;
    }
}
