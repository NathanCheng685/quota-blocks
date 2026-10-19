import Foundation

enum QuotaProvider: String, Sendable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"

    var colorName: String {
        switch self {
        case .chatGPT: "ChatGPTGreen"
        case .claude: "ClaudeClay"
        }
    }
}

enum QuotaPlan {
    private static let displayNames: [String: String] = [
        "free": "Free",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro 100",
        "pro_lite": "Pro 100",
        "go": "Go",
        "team": "Team",
        "business": "Business",
        "enterprise": "Enterprise",
        "edu": "Edu",
        "max": "Max",
        "max_5x": "Max 5x",
        "max_20x": "Max 20x",
    ]

    /// Providers report plans as lowercase identifiers ("pro", "prolite",
    /// "max_5x"). Map the known ones to their product names and prettify the
    /// rest so a brand-new plan id still renders reasonably.
    static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if let known = displayNames[value] { return known }
        return value
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

struct QuotaWindow: Sendable, Equatable {
    let usedPercent: Int
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var filledBlockCount: Int {
        guard remainingPercent > 0 else { return 0 }
        return min(5, Int(ceil(Double(remainingPercent) / 20.0)))
    }
}

/// A one-off limit reset Anthropic has granted the account, such as a model
/// launch promotion. Quota Blocks only reports it; spending it stays in
/// Claude Code (`/limit-reset`).
struct QuotaResetGrant: Sendable, Equatable {
    let label: String
    let resetsLeft: Int
    let endsAt: Date?
}

struct QuotaSnapshot: Sendable, Equatable {
    let provider: QuotaProvider
    let plan: String?
    let weekly: QuotaWindow
    let session: QuotaWindow?
    let fable: QuotaWindow?
    let resetGrants: [QuotaResetGrant]

    init(
        provider: QuotaProvider,
        usedPercent: Int,
        resetsAt: Date?,
        session: QuotaWindow? = nil,
        fable: QuotaWindow? = nil,
        plan: String? = nil,
        resetGrants: [QuotaResetGrant] = []
    ) {
        self.provider = provider
        self.plan = plan
        weekly = QuotaWindow(usedPercent: usedPercent, resetsAt: resetsAt)
        self.session = session
        self.fable = fable
        self.resetGrants = resetGrants
    }

    var usedPercent: Int { weekly.usedPercent }
    var resetsAt: Date? { weekly.resetsAt }
    var remainingPercent: Int { weekly.remainingPercent }
    var filledBlockCount: Int { weekly.filledBlockCount }
}

/// Why a provider is unavailable, in a form the menu can localize.
enum QuotaFailureKind: Sendable, Equatable {
    case executableMissing
    case notSignedIn
    case credentialsExpired
    case rateLimited(until: Date?)
    case temporary
}

enum QuotaState: Sendable, Equatable {
    case loading
    case available(QuotaSnapshot)
    case unavailable(QuotaFailureKind)

    var remainingPercent: Int? {
        if case let .available(snapshot) = self { return snapshot.remainingPercent }
        return nil
    }
}

enum QuotaError: LocalizedError {
    case executableMissing
    case notSignedIn(String)
    case credentialsExpired(String)
    case rateLimited(String, until: Date?)
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "未找到 ChatGPT/Codex，请先安装 ChatGPT 应用。"
        case let .notSignedIn(provider):
            "\(provider) 未登录，请先打开对应应用完成登录。"
        case let .credentialsExpired(provider):
            "\(provider) 登录凭据已过期，使用一次 \(provider) Code 后会自动恢复。"
        case let .rateLimited(provider, until):
            if let until {
                "\(provider) 额度接口暂时限流，\(Self.clockTime(until)) 后自动重试。"
            } else {
                "\(provider) 额度接口暂时限流，稍后自动重试。"
            }
        case let .invalidResponse(provider):
            "\(provider) 暂时没有返回周额度。"
        case let .requestFailed(message):
            message
        }
    }

    var isTemporary: Bool {
        switch self {
        case .invalidResponse, .requestFailed, .rateLimited:
            true
        case .executableMissing, .notSignedIn, .credentialsExpired:
            false
        }
    }

    var failureKind: QuotaFailureKind {
        switch self {
        case .executableMissing: .executableMissing
        case .notSignedIn: .notSignedIn
        case .credentialsExpired: .credentialsExpired
        case let .rateLimited(_, until): .rateLimited(until: until)
        case .invalidResponse, .requestFailed: .temporary
        }
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
