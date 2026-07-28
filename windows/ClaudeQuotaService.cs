using System.Net.Http.Headers;
using System.Text.Json;

namespace QuotaBlocks;

/// <summary>
/// Claude quotas come from whichever local source is actually signed in.
///
/// Preferred: the Claude Code CLI's OAuth session (~/.claude/.credentials.json)
/// plus Anthropic's usage endpoint, which also reports reset times and the Fable
/// limit. Those credentials are treated as strictly read-only — Claude Code owns
/// and rotates them.
///
/// Fallback: the Claude desktop app's own usage log
/// (%APPDATA%\Claude\plan-usage-history.json). No network, no credentials, but
/// only the used percentages, and it only advances while the desktop app runs.
/// </summary>
public static class ClaudeQuotaService
{
    private const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";
    private static readonly TimeSpan ExpiryLeeway = TimeSpan.FromSeconds(60);

    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        UseCookies = false,
    })
    {
        Timeout = TimeSpan.FromSeconds(20),
    };

    public static async Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        var token = ReadAccessToken();
        if (token is not null)
        {
            try
            {
                return await FetchFromApiAsync(token, cancellationToken).ConfigureAwait(false);
            }
            catch (QuotaException) when (ReadDesktopUsage() is not null)
            {
                // The signed-in path broke; the desktop log is still better than a blank row.
            }
            catch (HttpRequestException) when (ReadDesktopUsage() is not null)
            {
            }
        }

        return ReadDesktopUsage()
            ?? throw QuotaException.NotSignedIn("Claude");
    }

    /// <summary>Human-readable rundown of every source, for the details popup.</summary>
    public static string Diagnostics()
    {
        var lines = new List<string>();

        var path = CredentialsPath;
        if (!File.Exists(path))
        {
            lines.Add("CLI 凭据: 不存在");
        }
        else
        {
            var expiry = ReadExpiry();
            lines.Add(expiry is null
                ? "CLI 凭据: 无法解析"
                : $"CLI 凭据: {(expiry > DateTime.Now ? "有效" : "已过期")} ({expiry:yyyy-MM-dd HH:mm})");
        }

        var desktop = ReadDesktopSample();
        lines.Add(desktop is null
            ? "桌面版记录: 不存在"
            : $"桌面版记录: {desktop.Value.Timestamp:MM-dd HH:mm}");

        return string.Join("\n", lines);
    }

    private static async Task<QuotaSnapshot> FetchFromApiAsync(string token, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        request.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.0");

        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)
        {
            throw QuotaException.NotSignedIn("Claude");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw QuotaException.Temporary($"Claude 额度读取失败（HTTP {(int)response.StatusCode}）。");
        }

        var payload = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        return ParseUsage(payload);
    }

    internal static QuotaSnapshot ParseUsage(string payload)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;

        QuotaWindow? weekly = null, session = null, fable = null;

        if (root.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
        {
            foreach (var limit in limits.EnumerateArray())
            {
                var kind = limit.TryGetProperty("kind", out var k) ? k.GetString() : null;
                var hasScope = limit.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.Object;

                if (kind == "weekly_all" && !hasScope) weekly ??= WindowFrom(limit, "percent");
                else if (kind == "session") session ??= WindowFrom(limit, "percent");
                else if (hasScope &&
                         scope.TryGetProperty("model", out var model) &&
                         model.TryGetProperty("display_name", out var name) &&
                         string.Equals(name.GetString(), "Fable", StringComparison.OrdinalIgnoreCase))
                {
                    fable ??= WindowFrom(limit, "percent");
                }
            }
        }

        weekly ??= Legacy(root, "seven_day");
        session ??= Legacy(root, "five_hour");

        if (weekly is null) throw QuotaException.Temporary("Claude 暂时没有返回周额度。");

        return new QuotaSnapshot(
            QuotaProvider.Claude, weekly, session, fable, "Fable", QuotaSource.ClaudeCodeCli);
    }

    private static QuotaWindow? Legacy(JsonElement root, string name) =>
        root.TryGetProperty(name, out var legacy) && legacy.ValueKind == JsonValueKind.Object
            ? WindowFrom(legacy, "utilization")
            : null;

    private static QuotaWindow? WindowFrom(JsonElement element, string percentName)
    {
        if (!element.TryGetProperty(percentName, out var percent) || percent.ValueKind != JsonValueKind.Number) return null;

        DateTime? resetsAt = null;
        if (element.TryGetProperty("resets_at", out var reset) &&
            reset.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(reset.GetString(), out var parsed))
        {
            resetsAt = parsed.LocalDateTime;
        }

        return new QuotaWindow(Math.Clamp((int)Math.Round(percent.GetDouble()), 0, 100), resetsAt);
    }

    private static string CredentialsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", ".credentials.json");

    private static string DesktopUsagePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "plan-usage-history.json");

    private static JsonElement? OauthElement()
    {
        try
        {
            if (!File.Exists(CredentialsPath)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(CredentialsPath));
            return document.RootElement.TryGetProperty("claudeAiOauth", out var oauth)
                ? oauth.Clone()
                : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static DateTime? ReadExpiry()
    {
        var oauth = OauthElement();
        if (oauth is null) return null;
        return oauth.Value.TryGetProperty("expiresAt", out var expires) && expires.ValueKind == JsonValueKind.Number
            ? DateTimeOffset.FromUnixTimeMilliseconds(expires.GetInt64()).LocalDateTime
            : null;
    }

    private static string? ReadAccessToken()
    {
        var oauth = OauthElement();
        if (oauth is null) return null;

        var token = oauth.Value.TryGetProperty("accessToken", out var t) ? t.GetString() : null;
        if (string.IsNullOrEmpty(token)) return null;

        var expiry = ReadExpiry();
        if (expiry is not null && expiry.Value - DateTime.Now <= ExpiryLeeway) return null;

        return token;
    }

    private readonly record struct DesktopSample(DateTime Timestamp, int? FiveHour, int? SevenDay);

    private static DesktopSample? ReadDesktopSample()
    {
        try
        {
            if (!File.Exists(DesktopUsagePath)) return null;

            using var stream = new FileStream(
                DesktopUsagePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var document = JsonDocument.Parse(stream);

            if (!document.RootElement.TryGetProperty("samples", out var samples) ||
                samples.ValueKind != JsonValueKind.Array ||
                samples.GetArrayLength() == 0)
            {
                return null;
            }

            var last = samples[samples.GetArrayLength() - 1];
            if (!last.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.Number) return null;
            if (!last.TryGetProperty("u", out var used) || used.ValueKind != JsonValueKind.Object) return null;

            return new DesktopSample(
                DateTimeOffset.FromUnixTimeMilliseconds(t.GetInt64()).LocalDateTime,
                Percent(used, "fh"),
                Percent(used, "sd"));
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }

        static int? Percent(JsonElement element, string name) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
                ? Math.Clamp((int)Math.Round(value.GetDouble()), 0, 100)
                : null;
    }

    private static QuotaSnapshot? ReadDesktopUsage()
    {
        if (ReadDesktopSample() is not { } sample || sample.SevenDay is null) return null;

        return new QuotaSnapshot(
            QuotaProvider.Claude,
            new QuotaWindow(sample.SevenDay.Value, ResetsAt: null),
            sample.FiveHour is null ? null : new QuotaWindow(sample.FiveHour.Value, ResetsAt: null),
            Source: QuotaSource.ClaudeDesktopLog,
            SourceSampledAt: sample.Timestamp);
    }
}
