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
