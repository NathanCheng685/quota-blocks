using System.Diagnostics;
using System.Text.Json;

namespace QuotaBlocks;

/// <summary>
/// Reads the ChatGPT/Codex weekly rate limit by speaking the Codex app-server
/// JSON-RPC protocol over stdio, exactly as the Codex desktop app does.
/// </summary>
public static class CodexQuotaService
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(25);

    public static async Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        var exe = LocateExecutable()
            ?? throw QuotaException.Missing("未找到 Codex，请先安装 Codex / ChatGPT 应用。");

        var info = new ProcessStartInfo(exe, "app-server")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };

        using var process = Process.Start(info)
            ?? throw QuotaException.Temporary("无法启动 Codex 额度读取。");

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);

        // ConfigureAwait(false) throughout: the caller is the UI thread, and the
        // teardown in the finally below waits on a process. A global mouse hook
        // lives on that thread while the details panel is open, so blocking it
        // would stall input for the whole machine.
        try
        {
            await process.StandardInput.WriteLineAsync(
                """{"method":"initialize","id":0,"params":{"clientInfo":{"name":"quota_blocks","title":"Quota Blocks","version":"1.0.0"}}}""")
                .ConfigureAwait(false);
            await process.StandardInput.WriteLineAsync("""{"method":"initialized","params":{}}""")
                .ConfigureAwait(false);
            await process.StandardInput.WriteLineAsync("""{"method":"account/rateLimits/read","id":1,"params":{}}""")
                .ConfigureAwait(false);
            await process.StandardInput.FlushAsync(timeout.Token).ConfigureAwait(false);

            while (!timeout.IsCancellationRequested)
            {
                var line = await process.StandardOutput.ReadLineAsync(timeout.Token).ConfigureAwait(false);
                if (line is null) break;
                var snapshot = Parse(line);
                if (snapshot is not null) return snapshot;
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw QuotaException.Temporary("Codex 额度读取超时。");
        }
        finally
        {
            TryKill(process);
        }

        throw QuotaException.Temporary("Codex 未返回周额度。");
    }

    /// <summary>Returns null for protocol chatter that is not the id:1 reply.</summary>
    internal static QuotaSnapshot? Parse(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;

        JsonDocument document;
        try { document = JsonDocument.Parse(line); }
        catch (JsonException) { return null; }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.Number || id.GetInt32() != 1) return null;
            if (!root.TryGetProperty("result", out var result)) return null;

            JsonElement limits = default;
            var found = false;
            if (result.TryGetProperty("rateLimitsByLimitId", out var byId) &&
                byId.ValueKind == JsonValueKind.Object &&
                byId.TryGetProperty("codex", out var preferred))
            {
                limits = preferred;
                found = true;
            }
            else if (result.TryGetProperty("rateLimits", out var fallback) && fallback.ValueKind == JsonValueKind.Object)
            {
                limits = fallback;
                found = true;
            }

            if (!found) throw QuotaException.Temporary("Codex 返回的额度格式无法识别。");

            var primary = Window(limits, "primary");
            var secondary = Window(limits, "secondary");

            // Prefer whichever window actually spans a week; some plans report it as secondary.
            var weekly = new[] { primary, secondary }
                .FirstOrDefault(w => w is { DurationMinutes: >= 7 * 24 * 60 })
                ?? primary ?? secondary;

            if (weekly is null) throw QuotaException.Temporary("Codex 暂时没有返回周额度。");

            var session = primary is not null && !ReferenceEquals(primary, weekly) ? primary : null;

            return new QuotaSnapshot(
                QuotaProvider.Codex,
                new QuotaWindow(weekly.UsedPercent, weekly.ResetsAt),
                session is null ? null : new QuotaWindow(session.UsedPercent, session.ResetsAt));
        }
    }

    private sealed record RawWindow(int UsedPercent, DateTime? ResetsAt, int DurationMinutes);

    private static RawWindow? Window(JsonElement limits, string name)
    {
        if (!limits.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object) return null;
        if (!value.TryGetProperty("usedPercent", out var used) || used.ValueKind != JsonValueKind.Number) return null;

        var duration = value.TryGetProperty("windowDurationMins", out var mins) && mins.ValueKind == JsonValueKind.Number
            ? mins.GetInt32()
            : 0;
        DateTime? resetsAt = value.TryGetProperty("resetsAt", out var reset) && reset.ValueKind == JsonValueKind.Number
            ? DateTimeOffset.FromUnixTimeSeconds(reset.GetInt64()).LocalDateTime
            : null;

        return new RawWindow(Math.Clamp((int)Math.Round(used.GetDouble()), 0, 100), resetsAt, duration);
    }

    /// <summary>
    /// The desktop app unpacks a runnable copy under LOCALAPPDATA; the one inside
    /// the WindowsApps package directory refuses to launch (ACL), so it is last.
    /// </summary>
    internal static string? LocateExecutable()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        var unpacked = SafeEnumerate(Path.Combine(local, "OpenAI", "Codex", "bin"), "codex.exe")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
        if (unpacked is not null) return unpacked;

        foreach (var root in new[] { "C:\\Program Files\\WindowsApps", Path.Combine(local, "Programs") })
        {
            var packaged = SafeEnumerate(root, "codex.exe")
                .Where(p => p.Contains("Codex", StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            if (packaged is not null) return packaged;
        }

        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory.Trim(), "codex.exe");
            if (File.Exists(candidate)) return candidate;
        }

        return null;
    }

    private static IEnumerable<string> SafeEnumerate(string root, string pattern)
    {
        if (!Directory.Exists(root)) return [];
        try
        {
            return Directory.EnumerateFiles(root, pattern, new EnumerationOptions
            {
                RecurseSubdirectories = true,
                MaxRecursionDepth = 4,
                IgnoreInaccessible = true,
            });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            process.StandardInput.Close();
            if (!process.WaitForExit(500)) process.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is InvalidOperationException or IOException or NotSupportedException)
        {
            // Already gone.
        }
    }
}
