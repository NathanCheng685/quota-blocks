import Foundation

enum QuotaParsers {
    static func parseCodexLine(_ data: Data) throws -> QuotaSnapshot? {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = root["id"] as? Int,
            id == 1,
            let result = root["result"] as? [String: Any]
        else { return nil }

        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let preferred = byID?["codex"] as? [String: Any]
        let fallback = result["rateLimits"] as? [String: Any]
        guard let limits = preferred ?? fallback else {
            throw QuotaError.invalidResponse("ChatGPT")
        }

        let primary = limits["primary"] as? [String: Any]
        let secondary = limits["secondary"] as? [String: Any]
        let weekly = [primary, secondary]
            .compactMap { $0 }
            .first { ($0["windowDurationMins"] as? NSNumber)?.intValue ?? 0 >= 7 * 24 * 60 }
            ?? primary
            ?? secondary

        guard let weekly,
              let used = (weekly["usedPercent"] as? NSNumber)?.intValue
        else {
            throw QuotaError.invalidResponse("ChatGPT")
        }

        let resetTimestamp = (weekly["resetsAt"] as? NSNumber)?.doubleValue
        return QuotaSnapshot(
            provider: .chatGPT,
            usedPercent: max(0, min(100, used)),
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    static func parseClaudeUsage(_ data: Data) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse("Claude")
        }

        let limits = root["limits"] as? [[String: Any]] ?? []
        let weeklyLimit = limits.first {
            ($0["kind"] as? String) == "weekly_all" && ($0["scope"] is NSNull || $0["scope"] == nil)
        }
        let sessionLimit = limits.first { ($0["kind"] as? String) == "session" }
        let fableLimit = limits.first { limit in
            guard
                let scope = limit["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let name = model["display_name"] as? String
            else { return false }
            return name.caseInsensitiveCompare("Fable") == .orderedSame
        }

        let legacyWeekly = window(fromLegacy: root["seven_day"] as? [String: Any])
        guard let weekly = window(fromLimit: weeklyLimit) ?? legacyWeekly else {
            throw QuotaError.invalidResponse("Claude")
        }
        let session = window(fromLimit: sessionLimit)
            ?? window(fromLegacy: root["five_hour"] as? [String: Any])
        let fable = window(fromLimit: fableLimit)

        return QuotaSnapshot(
            provider: .claude,
            usedPercent: weekly.usedPercent,
            resetsAt: weekly.resetsAt,
            session: session,
            fable: fable
        )
    }

    private static func window(fromLimit value: [String: Any]?) -> QuotaWindow? {
        guard let value, let percent = (value["percent"] as? NSNumber)?.doubleValue else { return nil }
        return QuotaWindow(
            usedPercent: clamp(percent),
            resetsAt: (value["resets_at"] as? String).flatMap(parseISO8601)
        )
    }

    private static func window(fromLegacy value: [String: Any]?) -> QuotaWindow? {
        guard let value, let percent = (value["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return QuotaWindow(
            usedPercent: clamp(percent),
            resetsAt: (value["resets_at"] as? String).flatMap(parseISO8601)
        )
    }

    private static func clamp(_ percent: Double) -> Int {
        max(0, min(100, Int(percent.rounded())))
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
