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

        let session = [primary, secondary]
            .compactMap { $0 as [String: Any]? }
            .first { ($0["windowDurationMins"] as? NSNumber)?.intValue == 5 * 60 }
            .flatMap { value -> QuotaWindow? in
                guard let used = (value["usedPercent"] as? NSNumber)?.intValue else { return nil }
                return QuotaWindow(
                    usedPercent: max(0, min(100, used)),
                    resetsAt: ((value["resetsAt"] as? NSNumber)?.doubleValue).map(Date.init(timeIntervalSince1970:))
                )
            }

        let resetTimestamp = (weekly["resetsAt"] as? NSNumber)?.doubleValue
        return QuotaSnapshot(
            provider: .chatGPT,
            usedPercent: max(0, min(100, used)),
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:)),
            session: session,
            plan: QuotaPlan.displayName(limits["planType"] as? String)
        )
    }

    static func parseClaudeUsage(
        _ data: Data,
        planName: String? = nil,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
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
            fable: fable,
            plan: planName,
            resetGrants: resetGrants(from: root["cedar_ember"] as? [String: Any], now: now)
        )
    }

    /// The exact Claude plan from `/api/oauth/profile`, in the same order
    /// Claude Code uses: the server's own display name (for a plan such as
    /// "Pro 100"), then the Max rate-limit tier, then the organization type.
    static func parseClaudeProfilePlan(_ data: Data) -> String? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let organization = root["organization"] as? [String: Any]
        else { return nil }

        if let display = (organization["plan_display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !display.isEmpty, display.count <= 40
        {
            return display.replacingOccurrences(of: #"^Claude\s+"#, with: "", options: .regularExpression)
        }

        let type = organization["organization_type"] as? String
        let tier = organization["rate_limit_tier"] as? String
        if type == nil || type == "claude_max" {
            switch tier {
            case "default_claude_max_5x": return QuotaPlan.displayName("max_5x")
            case "default_claude_max_20x": return QuotaPlan.displayName("max_20x")
            default: break
            }
        }
        guard let type, type.hasPrefix("claude_") else { return nil }
        return QuotaPlan.displayName(String(type.dropFirst("claude_".count)))
    }

    /// Limit resets granted to the account. The server only fills these in
    /// for an eligible client; anything paused, spent or past its deadline is
    /// left out so the menu never offers a reset that cannot be used.
    static func resetGrants(from status: [String: Any]?, now: Date) -> [QuotaResetGrant] {
        guard let status, status["eligible"] as? Bool == true else { return [] }
        let grants = status["grants"] as? [[String: Any]] ?? []
        return grants.compactMap { grant in
            guard
                let left = (grant["resets_left"] as? NSNumber)?.intValue, left > 0,
                grant["paused"] as? Bool != true
            else { return nil }
            let endsAt = (grant["ends_at"] as? String).flatMap(parseISO8601)
            if let endsAt, endsAt <= now { return nil }
            return QuotaResetGrant(
                label: grant["label"] as? String ?? "",
                resetsLeft: left,
                endsAt: endsAt
            )
        }
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
