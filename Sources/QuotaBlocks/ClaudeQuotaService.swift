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
            let refreshedToken = try await credentialStore.accessToken(
                forceRefresh: true,
                rejectedToken: token
            )
            return try await fetchUsage(with: refreshedToken)
        }
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

struct ClaudeOAuthRefreshPayload {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval

    init(data: Data) throws {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = root["access_token"] as? String,
            !accessToken.isEmpty
        else {
            throw QuotaError.invalidResponse("Claude OAuth")
        }

        self.accessToken = accessToken
        refreshToken = root["refresh_token"] as? String
        expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    }
}

actor ClaudeCredentialStore {
    private enum Storage {
        case keychain(service: String, account: String)
        case file(URL)
    }

    private struct Credentials {
        var root: [String: Any]
        let accessToken: String
        let refreshToken: String?
        let expiresAtMilliseconds: TimeInterval?
        let storage: Storage
    }

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]
    private static let refreshLeeway: TimeInterval = 60
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func accessToken(
        forceRefresh: Bool = false,
        rejectedToken: String? = nil
    ) async throws -> String {
        let credentials = try readCredentials()
        // Claude Code may have refreshed the token while Quota Blocks was making
        // its request. Prefer the new on-disk token instead of refreshing again.
        if let rejectedToken, credentials.accessToken != rejectedToken {
            return credentials.accessToken
        }

        if !forceRefresh, !Self.needsRefresh(
            expiresAtMilliseconds: credentials.expiresAtMilliseconds
        ) {
            return credentials.accessToken
        }

        return try await refresh(credentials)
    }

    static func needsRefresh(
        expiresAtMilliseconds: TimeInterval?,
        now: Date = Date()
    ) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt.timeIntervalSince(now) <= refreshLeeway
    }

    private func refresh(_ credentials: Credentials) async throws -> String {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw QuotaError.notSignedIn("Claude")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes.joined(separator: " "),
        ])

        let data = try await refreshResponseData(for: request)
        let payload = try ClaudeOAuthRefreshPayload(data: data)

        // Do not overwrite a newer credential set written by Claude Code while
        // this network request was in flight.
        let latest = try readCredentials()
        if latest.refreshToken != refreshToken,
           latest.accessToken != credentials.accessToken
        {
            return latest.accessToken
        }

        try write(
            payload: payload,
            into: latest,
            now: Date()
        )
        return payload.accessToken
    }

    private func refreshResponseData(
        for request: URLRequest,
        retryOnRateLimit: Bool = true
    ) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.requestFailed("Claude 登录刷新响应无效。")
        }

        switch http.statusCode {
        case 200:
            return data
        case 400, 401, 403:
            throw QuotaError.notSignedIn("Claude")
        case 429 where retryOnRateLimit:
            let headerDelay = TimeInterval(
                http.value(forHTTPHeaderField: "Retry-After") ?? ""
            )
            let delay = min(30, max(2, headerDelay ?? 10))
            try await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            return try await refreshResponseData(
                for: request,
                retryOnRateLimit: false
            )
        default:
            throw QuotaError.requestFailed("Claude 登录刷新失败（HTTP \(http.statusCode)）。")
        }
    }

    private func write(
        payload: ClaudeOAuthRefreshPayload,
        into credentials: Credentials,
        now: Date
    ) throws {
        var root = credentials.root
        guard var oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw QuotaError.notSignedIn("Claude")
        }

        oauth["accessToken"] = payload.accessToken
        if let refreshToken = payload.refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = Int64(
            (now.timeIntervalSince1970 + payload.expiresIn) * 1000
        )
        root["claudeAiOauth"] = oauth

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        switch credentials.storage {
        case let .keychain(service, account):
            try writeKeychain(
                data,
                service: service,
                account: account
            )
        case let .file(url):
            try data.write(to: url, options: .atomic)
        }
    }

    private func readCredentials() throws -> Credentials {
        if let keychainCredentials = try readKeychainCredentials() {
            return keychainCredentials
        }
        return try readFileCredentials()
    }

    private func readKeychainCredentials() throws -> Credentials? {
        let service = "Claude Code-credentials"
        let account = NSUserName()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw QuotaError.requestFailed("无法读取 Claude 钥匙串（错误 \(status)）。")
        }
        return try parseCredentials(
            data,
            storage: .keychain(service: service, account: account)
        )
    }

    private func readFileCredentials() throws -> Credentials {
        let url = credentialURL
        guard let data = try? Data(contentsOf: url) else {
            throw QuotaError.notSignedIn("Claude")
        }
        return try parseCredentials(data, storage: .file(url))
    }

    private func parseCredentials(
        _ data: Data,
        storage: Storage
    ) throws -> Credentials {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            throw QuotaError.notSignedIn("Claude")
        }

        return Credentials(
            root: root,
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMilliseconds: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
            storage: storage
        )
    }

    private func writeKeychain(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw QuotaError.requestFailed("无法更新 Claude 钥匙串（错误 \(status)）。")
        }
    }

    private var credentialURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }
}
