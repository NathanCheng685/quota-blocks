import Foundation

enum QuotaSelfTest {
    enum Failure: Error {
        case assertion(String)
    }

    static func run() throws {
        let codexJSON = #"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912}}}}}"#
        guard let codex = try QuotaParsers.parseCodexLine(Data(codexJSON.utf8)) else {
            throw Failure.assertion("Codex response was not recognized")
        }
        try expect(codex.remainingPercent == 60, "Codex remaining percentage")
        try expect(codex.filledBlockCount == 3, "Codex block count")

        let claudeJSON = #"{"five_hour":{"utilization":33.0,"resets_at":"2026-07-14T22:20:00+00:00"},"seven_day":{"utilization":47.0,"resets_at":"2026-07-15T23:00:00.121498+00:00"},"limits":[{"percent":33,"kind":"session","group":"session","resets_at":"2026-07-14T22:20:00+00:00","scope":null},{"percent":47,"kind":"weekly_all","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":null},{"percent":87,"kind":"weekly_scoped","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}"#
        let claude = try QuotaParsers.parseClaudeUsage(Data(claudeJSON.utf8))
        try expect(claude.remainingPercent == 53, "Claude remaining percentage")
        try expect(claude.filledBlockCount == 3, "Claude block count")
        try expect(claude.resetsAt != nil, "Claude reset date")
        try expect(claude.session?.remainingPercent == 67, "Claude session remaining percentage")
        try expect(claude.fable?.remainingPercent == 13, "Claude Fable remaining percentage")

        let now = Date(timeIntervalSince1970: 1_000)
        try expect(
            ClaudeCredentialStore.needsRefresh(
                expiresAtMilliseconds: 1_030_000,
                now: now
            ),
            "Claude token expiry leeway"
        )
        try expect(
            !ClaudeCredentialStore.needsRefresh(
                expiresAtMilliseconds: 1_120_000,
                now: now
            ),
            "Claude valid token"
        )
        try expect(
            QuotaError.requestFailed("rate limited").isTemporary,
            "Temporary request failure"
        )
        try expect(
            !QuotaError.notSignedIn("Claude").isTemporary,
            "Signed-out state is not temporary"
        )
        try expect(
            !QuotaError.credentialsExpired("Claude").isTemporary,
            "Expired credentials are not temporary"
        )

        let selectionNow = Date(timeIntervalSince1970: 10_000)
        let expiredToken = ClaudeCredentialStore.Credentials(
            accessToken: "expired-token",
            expiresAtMilliseconds: 9_000_000
        )
        let freshToken = ClaudeCredentialStore.Credentials(
            accessToken: "fresh-token",
            expiresAtMilliseconds: 20_000_000
        )
        let fresherToken = ClaudeCredentialStore.Credentials(
            accessToken: "fresher-token",
            expiresAtMilliseconds: 30_000_000
        )
        let eternalToken = ClaudeCredentialStore.Credentials(
            accessToken: "eternal-token",
            expiresAtMilliseconds: nil
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [expiredToken, freshToken],
                rejectedToken: nil,
                now: selectionNow
            ) == "fresh-token",
            "Fresh token wins over an expired one"
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [freshToken, fresherToken],
                rejectedToken: nil,
                now: selectionNow
            ) == "fresher-token",
            "Latest expiry wins between usable tokens"
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [freshToken, eternalToken],
                rejectedToken: nil,
                now: selectionNow
            ) == "eternal-token",
            "Token without expiry counts as farthest expiry"
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [expiredToken],
                rejectedToken: nil,
                now: selectionNow
            ) == nil,
            "Expired-only credentials yield no usable token"
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [freshToken],
                rejectedToken: "fresh-token",
                now: selectionNow
            ) == nil,
            "Server-rejected token is not reused"
        )
        try expect(
            ClaudeCredentialStore.usableToken(
                from: [expiredToken],
                rejectedToken: nil,
                now: Date(timeIntervalSince1970: 8_999),
                leeway: 0
            ) == "expired-token",
            "Zero leeway accepts a not-yet-expired token"
        )

        try expect(
            ClaudeCodeRefreshTrigger.shouldAttempt(lastAttemptAt: nil, now: selectionNow),
            "First refresh probe is allowed"
        )
        try expect(
            !ClaudeCodeRefreshTrigger.shouldAttempt(
                lastAttemptAt: selectionNow.addingTimeInterval(-30),
                now: selectionNow
            ),
            "Refresh probe honors the cooldown"
        )
        try expect(
            ClaudeCodeRefreshTrigger.shouldAttempt(
                lastAttemptAt: selectionNow.addingTimeInterval(-ClaudeCodeRefreshTrigger.attemptCooldown),
                now: selectionNow
            ),
            "Refresh probe resumes after the cooldown"
        )

        try expect(
            QuotaSnapshot(provider: .chatGPT, usedPercent: 100, resetsAt: nil).filledBlockCount == 0,
            "Empty block boundary"
        )
        try expect(
            QuotaSnapshot(provider: .chatGPT, usedPercent: 0, resetsAt: nil).filledBlockCount == 5,
            "Full block boundary"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure.assertion(name) }
    }
}
