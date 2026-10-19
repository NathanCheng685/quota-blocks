import Foundation

enum QuotaSelfTest {
    enum Failure: Error {
        case assertion(String)
    }

    static func run() throws {
        let codexJSON = #"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1784566912},"planType":"prolite"}}}}"#
        guard let codex = try QuotaParsers.parseCodexLine(Data(codexJSON.utf8)) else {
            throw Failure.assertion("Codex response was not recognized")
        }
        try expect(codex.remainingPercent == 60, "Codex remaining percentage")
        try expect(codex.filledBlockCount == 3, "Codex block count")
        try expect(codex.plan == "Pro 100", "Codex plan display name")

        try expect(codex.session == nil, "Weekly-only response has no session")
        for useByID in [false, true] {
            for swapWindows in [false, true] {
                let session: [String: Any] = ["usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1784000000]
                let weekly: [String: Any] = ["usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1784566912]
                let limits: [String: Any] = ["primary": swapWindows ? weekly : session, "secondary": swapWindows ? session : weekly]
                let result: [String: Any] = useByID
                    ? ["rateLimitsByLimitId": ["codex": limits], "rateLimits": ["primary": weekly]]
                    : ["rateLimits": limits]
                let data = try JSONSerialization.data(withJSONObject: ["id": 1, "result": result])
                let snapshot = try QuotaParsers.parseCodexLine(data)
                try expect(snapshot?.remainingPercent == 60, "Weekly quota stays independent of session")
                try expect(snapshot?.session?.remainingPercent == 77, "Session read from either response format and window order")
                try expect(snapshot?.session?.resetsAt == Date(timeIntervalSince1970: 1784000000), "Session uses its own reset date")
            }
        }
        let missingSessionUsage = #"{"id":1,"result":{"rateLimits":{"primary":{"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}}}"#
        let incomplete = try QuotaParsers.parseCodexLine(Data(missingSessionUsage.utf8))
        try expect(incomplete?.session == nil, "Missing session usage is not reported as zero")
        try expect(incomplete?.remainingPercent == 60, "Missing session usage preserves weekly quota")

        let claudeJSON = #"{"five_hour":{"utilization":33.0,"resets_at":"2026-07-14T22:20:00+00:00"},"seven_day":{"utilization":47.0,"resets_at":"2026-07-15T23:00:00.121498+00:00"},"limits":[{"percent":33,"kind":"session","group":"session","resets_at":"2026-07-14T22:20:00+00:00","scope":null},{"percent":47,"kind":"weekly_all","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":null},{"percent":87,"kind":"weekly_scoped","group":"weekly","resets_at":"2026-07-15T23:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}"#
        let claude = try QuotaParsers.parseClaudeUsage(Data(claudeJSON.utf8), planName: "Pro")
        try expect(claude.remainingPercent == 53, "Claude remaining percentage")
        try expect(claude.filledBlockCount == 3, "Claude block count")
        try expect(claude.resetsAt != nil, "Claude reset date")
        try expect(claude.session?.remainingPercent == 67, "Claude session remaining percentage")
        try expect(claude.fable?.remainingPercent == 13, "Claude Fable remaining percentage")
        try expect(claude.plan == "Pro", "Claude plan carried into the snapshot")

        try expect(QuotaPlan.displayName("pro") == "Pro", "Known plan id maps to product name")
        try expect(QuotaPlan.displayName("prolite") == "Pro 100", "ChatGPT prolite plan display name")
        try expect(QuotaPlan.displayName("max_5x") == "Max 5x", "Claude max_5x plan display name")
        try expect(QuotaPlan.displayName("team_plus") == "Team Plus", "Unknown plan id is prettified")
        try expect(QuotaPlan.displayName("  ") == nil, "Blank plan id yields no name")
        try expect(QuotaPlan.displayName(nil) == nil, "Missing plan id yields no name")

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
            !ClaudeCredentialStore.needsRefresh(
                expiresAtMilliseconds: 0,
                now: now
            ),
            "expiresAt 0 means unknown expiry, not expired"
        )
        try expect(
            QuotaError.requestFailed("rate limited").isTemporary,
            "Temporary request failure"
        )
        try expect(
            QuotaError.rateLimited("Claude", until: nil).isTemporary,
            "Rate limiting is temporary"
        )
        try expect(
            QuotaError.rateLimited("Claude", until: now).failureKind == .rateLimited(until: now),
            "Rate limit failure kind carries the retry date"
        )
        try expect(
            !QuotaError.notSignedIn("Claude").isTemporary,
            "Signed-out state is not temporary"
        )
        try expect(
            !QuotaError.credentialsExpired("Claude").isTemporary,
            "Expired credentials are not temporary"
        )
        try expect(
            QuotaError.notSignedIn("Claude").failureKind == .notSignedIn,
            "Signed-out failure kind"
        )

        try expect(
            ClaudeQuotaService.rateLimitBlockInterval(retryAfterSeconds: nil) == 300,
            "Missing Retry-After falls back to five minutes"
        )
        try expect(
            ClaudeQuotaService.rateLimitBlockInterval(retryAfterSeconds: 1_142) == 1_142,
            "Retry-After within bounds is honored"
        )
        try expect(
            ClaudeQuotaService.rateLimitBlockInterval(retryAfterSeconds: 5) == 60,
            "Tiny Retry-After is clamped up"
        )
        try expect(
            ClaudeQuotaService.rateLimitBlockInterval(retryAfterSeconds: 90_000) == 3_600,
            "Huge Retry-After is clamped down"
        )

        let stubJSON = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"subscriptionType":"pro"}}"#
        try expect(
            ClaudeCredentialStore.parseCredentials(Data(stubJSON.utf8)) == nil,
            "Blanked keychain stub yields no credentials"
        )
        let zeroExpiryJSON = #"{"claudeAiOauth":{"accessToken":"token-1","expiresAt":0,"subscriptionType":"max"}}"#
        let zeroExpiry = ClaudeCredentialStore.parseCredentials(Data(zeroExpiryJSON.utf8))
        try expect(zeroExpiry?.accessToken == "token-1", "Zero expiry token is kept")
        try expect(zeroExpiry?.expiresAtMilliseconds == nil, "Zero expiry becomes unknown expiry")
        try expect(zeroExpiry?.subscriptionType == "max", "Subscription type is parsed")

        let jsonPayload = Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8)
        try expect(
            ClaudeCredentialStore.decodeSecurityPayload(jsonPayload) == jsonPayload,
            "Plain JSON security output passes through"
        )
        let hexPayload = Data(jsonPayload.map { String(format: "%02x", $0) }.joined().utf8)
        try expect(
            ClaudeCredentialStore.decodeSecurityPayload(hexPayload) == jsonPayload,
            "Hex security output is decoded"
        )
        try expect(
            ClaudeCredentialStore.decodeSecurityPayload(Data("\n".utf8)) == nil,
            "Whitespace-only security output yields nothing"
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
            ClaudeCredentialStore.usableCredentials(
                from: [expiredToken, freshToken],
                rejectedToken: nil,
                now: selectionNow
            )?.accessToken == "fresh-token",
            "Fresh token wins over an expired one"
        )
        try expect(
            ClaudeCredentialStore.usableCredentials(
                from: [freshToken, fresherToken],
                rejectedToken: nil,
                now: selectionNow
            )?.accessToken == "fresher-token",
            "Latest expiry wins between usable tokens"
        )
        try expect(
            ClaudeCredentialStore.usableCredentials(
                from: [freshToken, eternalToken],
                rejectedToken: nil,
                now: selectionNow
            )?.accessToken == "eternal-token",
            "Token without expiry counts as farthest expiry"
        )
        try expect(
            ClaudeCredentialStore.usableCredentials(
                from: [expiredToken],
                rejectedToken: nil,
                now: selectionNow
            ) == nil,
            "Expired-only credentials yield no usable token"
        )
        try expect(
            ClaudeCredentialStore.usableCredentials(
                from: [freshToken],
                rejectedToken: "fresh-token",
                now: selectionNow
            ) == nil,
            "Server-rejected token is not reused"
        )
        try expect(
            ClaudeCredentialStore.usableCredentials(
                from: [expiredToken],
                rejectedToken: nil,
                now: Date(timeIntervalSince1970: 8_999),
                leeway: 0
            )?.accessToken == "expired-token",
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
