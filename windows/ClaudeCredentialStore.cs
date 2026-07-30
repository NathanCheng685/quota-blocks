using System.Text.Json;

namespace QuotaBlocks;

/// <summary>
/// Owns Claude Code credential selection and refresh. Claude Code remains the
/// only process that rotates or writes its OAuth credentials.
/// </summary>
internal sealed class ClaudeCredentialStore
{
    internal static readonly TimeSpan RefreshLeeway = TimeSpan.FromSeconds(60);

    private readonly string _credentialsPath;
    private readonly Func<DateTimeOffset> _now;
    private readonly Func<CancellationToken, Task<bool>> _requestRefresh;

    internal ClaudeCredentialStore()
        : this(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".claude",
                ".credentials.json"),
            () => DateTimeOffset.Now,
            ClaudeCodeRefreshTrigger.RequestAsync)
    {
    }

    internal ClaudeCredentialStore(
        string credentialsPath,
        Func<DateTimeOffset> now,
        Func<CancellationToken, Task<bool>> requestRefresh)
    {
        _credentialsPath = credentialsPath;
        _now = now;
        _requestRefresh = requestRefresh;
    }

    internal async Task<string?> AccessTokenAsync(CancellationToken cancellationToken)
    {
        var credentials = ReadCredentials();
        var token = UsableToken(credentials, _now());
        if (token is not null || credentials is null) return token;

        // Claude Code owns its rotating refresh token. Ask the CLI to refresh
        // itself, then read the file it wrote rather than calling OAuth here.
        _ = await _requestRefresh(cancellationToken).ConfigureAwait(false);
        return UsableToken(ReadCredentials(), _now());
    }

    internal string Diagnostics()
    {
        if (!File.Exists(_credentialsPath)) return "CLI 凭据: 不存在";

        var credentials = ReadCredentials();
        if (credentials is null) return "CLI 凭据: 无法解析";

        var expiry = credentials.ExpiresAtMilliseconds is { } milliseconds
            ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).LocalDateTime
            : (DateTime?)null;
        return expiry is null
            ? "CLI 凭据: 有效（无过期时间）"
            : $"CLI 凭据: {(NeedsRefresh(credentials.ExpiresAtMilliseconds, _now()) ? "已过期" : "有效")} ({expiry:yyyy-MM-dd HH:mm})";
    }

    internal static bool NeedsRefresh(
        long? expiresAtMilliseconds,
        DateTimeOffset now,
        TimeSpan? leeway = null)
    {
        if (expiresAtMilliseconds is null) return false;
        var expiry = DateTimeOffset.FromUnixTimeMilliseconds(expiresAtMilliseconds.Value);
        return expiry - now <= (leeway ?? RefreshLeeway);
    }

    private static string? UsableToken(Credentials? credentials, DateTimeOffset now)
    {
        if (credentials is null ||
            string.IsNullOrEmpty(credentials.AccessToken) ||
            NeedsRefresh(credentials.ExpiresAtMilliseconds, now))
        {
            return null;
        }

        return credentials.AccessToken;
    }

    private Credentials? ReadCredentials()
    {
        try
        {
            if (!File.Exists(_credentialsPath)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(_credentialsPath));
            if (!document.RootElement.TryGetProperty("claudeAiOauth", out var oauth) ||
                oauth.ValueKind != JsonValueKind.Object ||
                !oauth.TryGetProperty("accessToken", out var accessToken) ||
                accessToken.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            long? expiresAt = oauth.TryGetProperty("expiresAt", out var expiry) &&
                              expiry.ValueKind == JsonValueKind.Number
                ? expiry.GetInt64()
                : null;
            return new Credentials(accessToken.GetString() ?? "", expiresAt);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private sealed record Credentials(string AccessToken, long? ExpiresAtMilliseconds);
}
