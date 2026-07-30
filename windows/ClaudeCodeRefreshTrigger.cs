using System.ComponentModel;
using System.Diagnostics;

namespace QuotaBlocks;

/// <summary>
/// Runs Claude Code once so it can refresh its own expired OAuth access token.
/// The deliberately invalid model prevents a real inference request.
/// </summary>
internal static class ClaudeCodeRefreshTrigger
{
    internal static readonly TimeSpan AttemptCooldown = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(90);
    private const string ProbeModel = "quota-blocks-refresh-probe";
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static DateTimeOffset? _lastAttemptAt;

    internal static async Task<bool> RequestAsync(CancellationToken cancellationToken)
    {
        await Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var now = DateTimeOffset.Now;
            if (!ShouldAttempt(_lastAttemptAt, now)) return false;
            _lastAttemptAt = now;

            var executable = LocateExecutable();
            return executable is not null &&
                   await RunProbeAsync(executable, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Gate.Release();
        }
    }

    internal static bool ShouldAttempt(DateTimeOffset? lastAttemptAt, DateTimeOffset now) =>
        lastAttemptAt is null || now - lastAttemptAt >= AttemptCooldown;

    internal static string? LocateExecutable()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(home, ".claude", "local", "claude.exe"),
        };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate)) return candidate;
        }

        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory.Trim(), "claude.exe");
            if (File.Exists(candidate)) return candidate;
        }

        return null;
    }

    private static async Task<bool> RunProbeAsync(
        string executable,
        CancellationToken cancellationToken)
    {
        var workingDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuotaBlocks",
            "claude-probe");

        try
        {
            Directory.CreateDirectory(workingDirectory);
            var info = new ProcessStartInfo(executable)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = workingDirectory,
            };
            foreach (var argument in new[]
                     {
                         "-p",
                         "--no-session-persistence",
                         "--strict-mcp-config",
                         "--mcp-config",
                         """{"mcpServers":{}}""",
                         "--model",
                         ProbeModel,
                         "ok",
                     })
            {
                info.ArgumentList.Add(argument);
            }

            using var process = Process.Start(info);
            if (process is null) return false;
            process.StandardInput.Close();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            try
            {
                await Task.WhenAll(
                        process.StandardOutput.ReadToEndAsync(timeout.Token),
                        process.StandardError.ReadToEndAsync(timeout.Token),
                        process.WaitForExitAsync(timeout.Token))
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                TryKill(process);
                return false;
            }
            catch
            {
                TryKill(process);
                throw;
            }

            // The invalid model should produce a non-zero exit after Claude Code
            // has already refreshed its credentials.
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or
                                  Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception or
                                  NotSupportedException)
        {
            // Already gone.
        }
    }
}
