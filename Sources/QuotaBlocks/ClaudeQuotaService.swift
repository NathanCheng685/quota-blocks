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
    private struct Credentials {
        let accessToken: String
        let expiresAtMilliseconds: TimeInterval?
    }

    private static let refreshLeeway: TimeInterval = 60

    func accessToken(
        rejectedToken: String? = nil
    ) async throws -> String {
        let credentials = try readCredentials()
        if let rejectedToken, credentials.accessToken == rejectedToken {
            throw QuotaError.notSignedIn("Claude")
        }
        guard !Self.needsRefresh(
            expiresAtMilliseconds: credentials.expiresAtMilliseconds
        ) else {
            throw QuotaError.notSignedIn("Claude")
        }
        return credentials.accessToken
    }

    static func needsRefresh(
        expiresAtMilliseconds: TimeInterval?,
        now: Date = Date()
    ) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt.timeIntervalSince(now) <= refreshLeeway
    }

    private func readCredentials() throws -> Credentials {
        do {
            if let keychainCredentials = try readKeychainCredentials() {
                return keychainCredentials
            }
        } catch {
            // Claude Code can replace its Keychain item while rotating OAuth
            // credentials. That may revoke an independently signed menu bar
            // app's access even though the legacy credential file still has a
            // usable access token. Fall through to the file before declaring
            // the user signed out; Quota Blocks never refreshes either source.
            if FileManager.default.fileExists(atPath: credentialURL.path) {
                return try readFileCredentials()
            }
            throw error
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
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            throw QuotaError.notSignedIn("Claude")
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw QuotaError.requestFailed("无法读取 Claude 钥匙串（错误 \(status)）。")
        }
        return try parseCredentials(
            data
        )
    }

    private func readFileCredentials() throws -> Credentials {
        let url = credentialURL
        guard let data = try? Data(contentsOf: url) else {
            throw QuotaError.notSignedIn("Claude")
        }
        return try parseCredentials(data)
    }

    private func parseCredentials(_ data: Data) throws -> Credentials {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            throw QuotaError.notSignedIn("Claude")
        }

        return Credentials(
            accessToken: accessToken,
            expiresAtMilliseconds: (oauth["expiresAt"] as? NSNumber)?.doubleValue
        )
    }

    private var credentialURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }
}
