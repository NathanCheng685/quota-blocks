import Foundation

enum ClaudeQuotaService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> QuotaSnapshot {
        let token = try accessToken()
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.requestFailed("Claude 网络响应无效。")
        }
        switch http.statusCode {
        case 200:
            return try QuotaParsers.parseClaudeUsage(data)
        case 401, 403:
            throw QuotaError.notSignedIn("Claude")
        default:
            throw QuotaError.requestFailed("Claude 额度读取失败（HTTP \(http.statusCode)）。")
        }
    }

    private static func accessToken() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw QuotaError.notSignedIn("Claude")
        }
        return token
    }
}
