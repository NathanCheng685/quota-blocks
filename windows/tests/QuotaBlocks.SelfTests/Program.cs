using System.Text.Json;
using QuotaBlocks;

internal static class Program
{
    private static int _passed;
    private static int _failed;

    private static async Task<int> Main()
    {
        await Run("Codex parser", TestCodexParser);
        await Run("Claude parser", TestClaudeParser);
        await Run("Quota block boundaries", TestQuotaBoundaries);
        await Run("Claude token expiry leeway", TestClaudeExpiryLeeway);
        await Run("Valid Claude token skips refresh", TestValidClaudeTokenSkipsRefresh);
        await Run("Missing Claude credentials skip refresh", TestMissingClaudeCredentialsSkipRefresh);
        await Run("Expired Claude token refresh", TestExpiredClaudeTokenRefresh);
        await Run("Claude refresh cooldown", TestRefreshCooldown);

        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    private static Task TestCodexParser()
    {
        const string payload =
            """{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912}}}}}""";
        var snapshot = CodexQuotaService.Parse(payload)
            ?? throw new InvalidOperationException("Codex response was not recognized.");

        Expect(snapshot.Weekly.RemainingPercent == 60, "Codex remaining percentage");
        Expect(snapshot.Weekly.FilledBlockCount == 3, "Codex block count");
        return Task.CompletedTask;
    }

    private static Task TestClaudeParser()
    {
        const string payload =
            """{"five_hour":{"utilization":33.0,"resets_at":"2026-07-14T22:20:00+00:00"},"seven_day":{"utilization":47.0,"resets_at":"2026-07-15T23:00:00.121498+00:00"},"limits":[{"percent":33,"kind":"session","group":"session","resets_at":"2026-07-14T22:20:00+00:00","scope":null},{"percent":47,"kind":"weekly_all","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":null},{"percent":87,"kind":"weekly_scoped","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}""";
        var snapshot = ClaudeQuotaService.ParseUsage(payload);

        Expect(snapshot.Weekly.RemainingPercent == 53, "Claude remaining percentage");
        Expect(snapshot.Weekly.FilledBlockCount == 3, "Claude block count");
        Expect(snapshot.Weekly.ResetsAt is not null, "Claude reset date");
        Expect(snapshot.Session?.RemainingPercent == 67, "Claude session percentage");
        Expect(snapshot.Extra?.RemainingPercent == 13, "Claude Fable percentage");
        return Task.CompletedTask;
    }

    private static Task TestQuotaBoundaries()
    {
        Expect(new QuotaWindow(100, null).FilledBlockCount == 0, "Empty block boundary");
        Expect(new QuotaWindow(0, null).FilledBlockCount == 5, "Full block boundary");
        return Task.CompletedTask;
    }

    private static Task TestClaudeExpiryLeeway()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000);
        Expect(
            ClaudeCredentialStore.NeedsRefresh(1_030_000, now),
            "Token inside refresh leeway");
        Expect(
            !ClaudeCredentialStore.NeedsRefresh(1_120_000, now),
            "Token outside refresh leeway");
        return Task.CompletedTask;
    }

    private static async Task TestValidClaudeTokenSkipsRefresh()
    {
        var directory = CreateTemporaryDirectory();
        var credentialsPath = Path.Combine(directory, ".credentials.json");

        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(10_000);
            WriteCredentials(credentialsPath, "valid-token", now.AddHours(8));
            var refreshAttempts = 0;
            var store = new ClaudeCredentialStore(
                credentialsPath,
                () => now,
                _ =>
                {
                    refreshAttempts++;
                    return Task.FromResult(true);
                });

            var token = await store.AccessTokenAsync(CancellationToken.None);

            Expect(token == "valid-token", "Existing valid token returned");
            Expect(refreshAttempts == 0, "Valid token did not start Claude CLI");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task TestMissingClaudeCredentialsSkipRefresh()
    {
        var directory = CreateTemporaryDirectory();

        try
        {
            var refreshAttempts = 0;
            var store = new ClaudeCredentialStore(
                Path.Combine(directory, ".credentials.json"),
                () => DateTimeOffset.FromUnixTimeSeconds(10_000),
                _ =>
                {
                    refreshAttempts++;
                    return Task.FromResult(true);
                });

            var token = await store.AccessTokenAsync(CancellationToken.None);

            Expect(token is null, "Missing credentials return no token");
            Expect(refreshAttempts == 0, "Missing credentials did not start Claude CLI");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task TestExpiredClaudeTokenRefresh()
    {
        var directory = CreateTemporaryDirectory();
        var credentialsPath = Path.Combine(directory, ".credentials.json");

        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(10_000);
            WriteCredentials(credentialsPath, "expired-token", now.AddMinutes(-1));
            var refreshAttempts = 0;
            var store = new ClaudeCredentialStore(
                credentialsPath,
                () => now,
                _ =>
                {
                    refreshAttempts++;
                    WriteCredentials(credentialsPath, "fresh-token", now.AddHours(8));
                    return Task.FromResult(true);
                });

            var token = await store.AccessTokenAsync(CancellationToken.None);

            Expect(token == "fresh-token", "Fresh token returned after CLI refresh");
            Expect(refreshAttempts == 1, "Exactly one refresh attempt");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static Task TestRefreshCooldown()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(10_000);
        Expect(ClaudeCodeRefreshTrigger.ShouldAttempt(null, now), "First probe allowed");
        Expect(
            !ClaudeCodeRefreshTrigger.ShouldAttempt(now.AddSeconds(-30), now),
            "Probe blocked inside cooldown");
        Expect(
            ClaudeCodeRefreshTrigger.ShouldAttempt(
                now - ClaudeCodeRefreshTrigger.AttemptCooldown,
                now),
            "Probe allowed after cooldown");
        return Task.CompletedTask;
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"quota-blocks-self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static void WriteCredentials(string path, string token, DateTimeOffset expiry)
    {
        var payload = new
        {
            claudeAiOauth = new
            {
                accessToken = token,
                refreshToken = "owned-by-claude-code",
                expiresAt = expiry.ToUnixTimeMilliseconds(),
            },
        };
        File.WriteAllText(path, JsonSerializer.Serialize(payload));
    }

    private static async Task Run(string name, Func<Task> test)
    {
        try
        {
            await test();
            _passed++;
            Console.WriteLine($"PASS {name}");
        }
        catch (Exception e)
        {
            _failed++;
            Console.WriteLine($"FAIL {name}: {e.Message}");
        }
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
