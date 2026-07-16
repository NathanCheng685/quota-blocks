import Foundation
import Security

enum ClaudeQuotaService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let credentialStore = ClaudeCredentialStore()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func fetch() async throws -> QuotaSnapshot {
        let token = try await credentialStore.accessToken()

        do {
            return try await fetchUsage(with: token)
        } catch ClaudeRequestError.unauthorized {
            // Claude Code owns and rotates its OAuth credentials. Re-read once
            // in case Claude Code refreshed them while this request was in
            // flight, but never refresh or write the shared token ourselves.
            let latestToken = try await credentialStore.accessToken(
                rejectedToken: token
            )
            return try await fetchUsage(with: latestToken)
        }
    }

    static func credentialDiagnostics() async -> String {
        await credentialStore.diagnostics()
    }

    private static func fetchUsage(with token: String) async throws -> QuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.requestFailed("Claude 网络响应无效。")
        }
        switch http.statusCode {
        case 200:
            return try QuotaParsers.parseClaudeUsage(data)
        case 401, 403:
            throw ClaudeRequestError.unauthorized
        default:
            throw QuotaError.requestFailed("Claude 额度读取失败（HTTP \(http.statusCode)）。")
        }
    }
}

private enum ClaudeRequestError: Error {
    case unauthorized
}

actor ClaudeCredentialStore {
    struct Credentials: Equatable {
        let accessToken: String
        let expiresAtMilliseconds: TimeInterval?
    }

    struct SourceReport {
        let name: String
        let detail: String
        let credentials: Credentials?
    }

    static let refreshLeeway: TimeInterval = 60
    private static let keychainService = "Claude Code-credentials"

    func accessToken(
        rejectedToken: String? = nil
    ) async throws -> String {
        var sources = loadSources()
        if let token = Self.usableToken(
            from: sources.compactMap(\.credentials),
            rejectedToken: rejectedToken,
            now: Date()
        ) {
            return token
        }
        guard sources.contains(where: { $0.credentials != nil }) else {
            throw QuotaError.notSignedIn("Claude")
        }

        // The stored access token is expired (or the server just rejected
        // it). Only Claude Code may refresh the shared rotating credentials,
        // so ask it to refresh itself and re-read whatever it wrote back.
        _ = await ClaudeCodeRefreshTrigger.shared.requestRefresh()

        sources = loadSources()
        let candidates = sources.compactMap(\.credentials)
        if let token = Self.usableToken(
            from: candidates,
            rejectedToken: rejectedToken,
            now: Date()
        ) {
            return token
        }
        // Accept a token inside the expiry leeway as a last resort; the
        // usage request will still surface a real server-side rejection.
        if let token = Self.usableToken(
            from: candidates,
            rejectedToken: rejectedToken,
            now: Date(),
            leeway: 0
        ) {
            return token
        }
        guard candidates.isEmpty else {
            throw QuotaError.credentialsExpired("Claude")
        }
        throw QuotaError.notSignedIn("Claude")
    }

    func diagnostics() -> String {
        let sources = loadSources()
        var lines = ["Claude credential diagnostics:"]
        for source in sources {
            lines.append("- \(source.name): \(source.detail)")
        }
        let token = Self.usableToken(
            from: sources.compactMap(\.credentials),
            rejectedToken: nil,
            now: Date()
        )
        lines.append("- usable access token: \(token == nil ? "no" : "yes")")
        let binary = ClaudeCodeRefreshTrigger.locateClaudeBinary()
        lines.append("- claude CLI: \(binary?.path ?? "not found")")
        return lines.joined(separator: "\n")
    }

    static func usableToken(
        from candidates: [Credentials],
        rejectedToken: String?,
        now: Date,
        leeway: TimeInterval = ClaudeCredentialStore.refreshLeeway
    ) -> String? {
        candidates
            .filter {
                !needsRefresh(
                    expiresAtMilliseconds: $0.expiresAtMilliseconds,
                    now: now,
                    leeway: leeway
                )
            }
            .filter { $0.accessToken != rejectedToken }
            .max { effectiveExpiry($0) < effectiveExpiry($1) }?
            .accessToken
    }

    static func needsRefresh(
        expiresAtMilliseconds: TimeInterval?,
        now: Date = Date(),
        leeway: TimeInterval = ClaudeCredentialStore.refreshLeeway
    ) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    private static func effectiveExpiry(_ credentials: Credentials) -> TimeInterval {
        credentials.expiresAtMilliseconds ?? .greatestFiniteMagnitude
    }

    private func loadSources() -> [SourceReport] {
        [keychainSource(), fileSource()]
    }

    // Claude Code 2.0 stored credentials in the login keychain; 2.1 stores
    // them in ~/.claude/.credentials.json. Read both, never write either,
    // and let the freshest usable token win.
    private func keychainSource() -> SourceReport {
        let name = "keychain \"\(Self.keychainService)\""
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: NSUserName(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return SourceReport(name: name, detail: "empty item", credentials: nil)
            }
            guard let credentials = Self.parseCredentials(data) else {
                return SourceReport(name: name, detail: "unrecognized payload", credentials: nil)
            }
            return SourceReport(
                name: name,
                detail: "found, \(Self.expiryDescription(credentials))",
                credentials: credentials
            )
        case errSecItemNotFound:
            return SourceReport(name: name, detail: "item not found (OSStatus \(status))", credentials: nil)
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return SourceReport(name: name, detail: "access denied (OSStatus \(status))", credentials: nil)
        default:
            return SourceReport(name: name, detail: "read failed (OSStatus \(status))", credentials: nil)
        }
    }

    private func fileSource() -> SourceReport {
        let url = credentialURL
        let name = "file ~/.claude/.credentials.json"
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SourceReport(name: name, detail: "missing", credentials: nil)
        }
        guard let data = try? Data(contentsOf: url) else {
            return SourceReport(name: name, detail: "unreadable", credentials: nil)
        }
        guard let credentials = Self.parseCredentials(data) else {
            return SourceReport(name: name, detail: "unrecognized payload", credentials: nil)
        }
        return SourceReport(
            name: name,
            detail: "found, \(Self.expiryDescription(credentials))",
            credentials: credentials
        )
    }

    private static func parseCredentials(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            return nil
        }

        return Credentials(
            accessToken: accessToken,
            expiresAtMilliseconds: (oauth["expiresAt"] as? NSNumber)?.doubleValue
        )
    }

    private static func expiryDescription(_ credentials: Credentials) -> String {
        guard let milliseconds = credentials.expiresAtMilliseconds else {
            return "no expiry"
        }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = ISO8601DateFormatter()
        let state = needsRefresh(expiresAtMilliseconds: milliseconds) ? "expired" : "valid"
        return "expires \(formatter.string(from: expiresAt)) (\(state))"
    }

    private var credentialURL: URL {
        // Claude Code resolves ~/.claude through $HOME (Node's os.homedir),
        // while NSHomeDirectory ignores $HOME on macOS; follow Claude Code so
        // both processes always agree on where the credentials live.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/.credentials.json")
    }
}
