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

struct QuotaSnapshot: Sendable, Equatable {
    let provider: QuotaProvider
    let weekly: QuotaWindow
    let session: QuotaWindow?
    let fable: QuotaWindow?

    init(
        provider: QuotaProvider,
        usedPercent: Int,
        resetsAt: Date?,
        session: QuotaWindow? = nil,
        fable: QuotaWindow? = nil
    ) {
        self.provider = provider
        weekly = QuotaWindow(usedPercent: usedPercent, resetsAt: resetsAt)
        self.session = session
        self.fable = fable
    }

    var usedPercent: Int { weekly.usedPercent }
    var resetsAt: Date? { weekly.resetsAt }
    var remainingPercent: Int { weekly.remainingPercent }
    var filledBlockCount: Int { weekly.filledBlockCount }
}

enum QuotaState: Sendable, Equatable {
    case loading
    case available(QuotaSnapshot)
    case unavailable(String)

    var remainingPercent: Int? {
        if case let .available(snapshot) = self { return snapshot.remainingPercent }
        return nil
    }
}

enum QuotaError: LocalizedError {
    case executableMissing
    case notSignedIn(String)
    case credentialsExpired(String)
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
        case let .invalidResponse(provider):
            "\(provider) 暂时没有返回周额度。"
        case let .requestFailed(message):
            message
        }
    }

    var isTemporary: Bool {
        switch self {
        case .invalidResponse, .requestFailed:
            true
        case .executableMissing, .notSignedIn, .credentialsExpired:
            false
        }
    }
}
