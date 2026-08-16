import Foundation

enum ClaudeQuotaService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let credentialStore = ClaudeCredentialStore()
    private static let rateLimitGate = QuotaRateLimitGate()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func fetch() async throws -> QuotaSnapshot {
        if let blockedUntil = await rateLimitGate.activeBlock() {
            throw QuotaError.rateLimited("Claude", until: blockedUntil)
        }

        let grant = try await credentialStore.grant()

        do {
            return try await fetchUsage(with: grant)
        } catch ClaudeRequestError.unauthorized {
            // Claude Code owns and rotates its OAuth credentials. Re-read once
            // in case Claude Code refreshed them while this request was in
            // flight, but never refresh or write the shared token ourselves.
            let latestGrant = try await credentialStore.grant(
                rejectedToken: grant.accessToken
            )
            return try await fetchUsage(with: latestGrant)
        }
    }

    static func credentialDiagnostics() async -> String {
        await credentialStore.diagnostics()
    }

    private static func fetchUsage(
        with grant: ClaudeCredentialStore.TokenGrant
    ) async throws -> QuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Bearer \(grant.accessToken)", forHTTPHeaderField: "Authorization")
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
            return try QuotaParsers.parseClaudeUsage(data, planName: grant.planName)
        case 401, 403:
            throw ClaudeRequestError.unauthorized
        case 429:
            // The usage endpoint rate-limits by IP address. Honor Retry-After
            // so refresh cycles stop hammering it, and keep showing the last
            // snapshot in the meantime.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            let blockedUntil = await rateLimitGate.block(
                for: rateLimitBlockInterval(retryAfterSeconds: retryAfter)
            )
            throw QuotaError.rateLimited("Claude", until: blockedUntil)
        default:
            throw QuotaError.requestFailed("Claude 额度读取失败（HTTP \(http.statusCode)）。")
        }
    }

    static func rateLimitBlockInterval(retryAfterSeconds: TimeInterval?) -> TimeInterval {
        min(max(retryAfterSeconds ?? 300, 60), 3600)
    }
}

private enum ClaudeRequestError: Error {
    case unauthorized
}

/// Remembers a server-side rate limit so scheduled refreshes skip the network
/// until the announced window has passed.
actor QuotaRateLimitGate {
    private var blockedUntil: Date?

    func activeBlock(now: Date = Date()) -> Date? {
        guard let blockedUntil, blockedUntil > now else { return nil }
        return blockedUntil
    }

    func block(for interval: TimeInterval, now: Date = Date()) -> Date {
        let until = now.addingTimeInterval(interval)
        blockedUntil = until
        return until
    }
}

actor ClaudeCredentialStore {
    struct Credentials: Equatable {
        let accessToken: String
        let expiresAtMilliseconds: TimeInterval?
        let subscriptionType: String?

        init(
            accessToken: String,
            expiresAtMilliseconds: TimeInterval?,
            subscriptionType: String? = nil
        ) {
            self.accessToken = accessToken
            self.expiresAtMilliseconds = expiresAtMilliseconds
            self.subscriptionType = subscriptionType
        }
    }

    struct TokenGrant {
        let accessToken: String
        let planName: String?
    }

    struct SourceReport {
        let name: String
        let detail: String
        let credentials: Credentials?
    }

    static let refreshLeeway: TimeInterval = 60
    private static let keychainService = "Claude Code-credentials"

    func grant(
        rejectedToken: String? = nil
    ) async throws -> TokenGrant {
        var sources = loadSources()
        if let credentials = Self.usableCredentials(
            from: sources.compactMap(\.credentials),
            rejectedToken: rejectedToken,
            now: Date()
        ) {
            return Self.grant(from: credentials)
        }

        // No usable token anywhere: either the stored one expired or Claude
        // Code moved its credentials again. Only Claude Code may refresh the
        // shared rotating credentials, so ask it to run once and re-read
        // whatever it wrote back.
        _ = await ClaudeCodeRefreshTrigger.shared.requestRefresh()

        sources = loadSources()
        let candidates = sources.compactMap(\.credentials)
        if let credentials = Self.usableCredentials(
            from: candidates,
            rejectedToken: rejectedToken,
            now: Date()
        ) {
            return Self.grant(from: credentials)
        }
        // Accept a token inside the expiry leeway as a last resort; the
        // usage request will still surface a real server-side rejection.
        if let credentials = Self.usableCredentials(
            from: candidates,
            rejectedToken: rejectedToken,
            now: Date(),
            leeway: 0
        ) {
            return Self.grant(from: credentials)
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
        let credentials = Self.usableCredentials(
            from: sources.compactMap(\.credentials),
            rejectedToken: nil,
            now: Date()
        )
        lines.append("- usable access token: \(credentials == nil ? "no" : "yes")")
        let subscription = sources
            .compactMap { $0.credentials?.subscriptionType }
            .first
        lines.append("- subscription: \(subscription ?? "unknown")")
        let binary = ClaudeCodeRefreshTrigger.locateClaudeBinary()
        lines.append("- claude CLI: \(binary?.path ?? "not found")")
        return lines.joined(separator: "\n")
    }

    private static func grant(from credentials: Credentials) -> TokenGrant {
        TokenGrant(
            accessToken: credentials.accessToken,
            planName: QuotaPlan.displayName(credentials.subscriptionType)
        )
    }

    static func usableCredentials(
        from candidates: [Credentials],
        rejectedToken: String?,
        now: Date,
        leeway: TimeInterval = ClaudeCredentialStore.refreshLeeway
    ) -> Credentials? {
        candidates
            .filter {
                !needsRefresh(
                    expiresAtMilliseconds: $0.expiresAtMilliseconds,
                    now: now,
                    leeway: leeway
                )
            }
            .filter { $0.accessToken != rejectedToken }
            .max { effectiveExpiry($0) < effectiveExpiry($1) }
    }

    static func needsRefresh(
        expiresAtMilliseconds: TimeInterval?,
        now: Date = Date(),
        leeway: TimeInterval = ClaudeCredentialStore.refreshLeeway
    ) -> Bool {
        // Claude Code writes expiresAt: 0 when it has no expiry to record;
        // that means "unknown", not "expired in 1970".
        guard let expiresAtMilliseconds, expiresAtMilliseconds > 0 else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    private static func effectiveExpiry(_ credentials: Credentials) -> TimeInterval {
        credentials.expiresAtMilliseconds ?? .greatestFiniteMagnitude
    }

    private func loadSources() -> [SourceReport] {
        [keychainSource(), fileSource()]
    }

    // Claude Code 2.0 and 2.2+ store credentials in the login keychain; 2.1
    // stored them in ~/.claude/.credentials.json. Read both, never write
    // either, and let the freshest usable token win.
    //
    // The keychain item is written through /usr/bin/security, so the item's
    // ACL trusts that system tool rather than any GUI app. Reading through
    // the same tool therefore never shows the macOS keychain password dialog,
    // unlike an in-process SecItemCopyMatching from an app the ACL does not
    // know — which is exactly what used to make macOS ask for the login
    // keychain password on every refresh.
    private func keychainSource() -> SourceReport {
        let name = "keychain \"\(Self.keychainService)\""
        var read = Self.runSecurityRead(account: NSUserName())
        if read.exitStatus != 0 {
            // The account attribute may not match the current username (for
            // example after a migration); match on the service alone then.
            let fallback = Self.runSecurityRead(account: nil)
            if fallback.exitStatus == 0 { read = fallback }
        }
        guard read.exitStatus == 0 else {
            let status = read.exitStatus.map { "exit \($0)" } ?? "timed out"
            let detail = read.errorText.isEmpty ? status : "\(read.errorText) (\(status))"
            return SourceReport(name: name, detail: detail, credentials: nil)
        }
        guard let payload = Self.decodeSecurityPayload(read.output) else {
            return SourceReport(name: name, detail: "empty item", credentials: nil)
        }
        guard let credentials = Self.parseCredentials(payload) else {
            return SourceReport(name: name, detail: "unrecognized or blank payload", credentials: nil)
        }
        return SourceReport(
            name: name,
            detail: "found, \(Self.expiryDescription(credentials))",
            credentials: credentials
        )
    }

    private struct SecurityReadResult {
        /// nil when the read timed out and was killed.
        let exitStatus: Int32?
        let output: Data
        let errorText: String
    }

    private static func runSecurityRead(account: String?) -> SecurityReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", keychainService]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return SecurityReadResult(
                exitStatus: nil,
                output: Data(),
                errorText: error.localizedDescription
            )
        }

        // `security` answers immediately when the caller is allowed. If a
        // future item ACL made it prompt instead, waiting forever would wedge
        // every refresh, so give up after a short deadline.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            return SecurityReadResult(exitStatus: nil, output: Data(), errorText: "")
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        return SecurityReadResult(
            exitStatus: process.terminationStatus,
            output: outputData,
            errorText: String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    // `security -w` prints the raw value when it is printable and a hex dump
    // otherwise; accept both.
    static func decodeSecurityPayload(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return data.isEmpty ? nil : data
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") { return Data(trimmed.utf8) }
        if let decoded = Data(hexEncoded: trimmed) { return decoded }
        return Data(trimmed.utf8)
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
            return SourceReport(name: name, detail: "unrecognized or blank payload", credentials: nil)
        }
        return SourceReport(
            name: name,
            detail: "found, \(Self.expiryDescription(credentials))",
            credentials: credentials
        )
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            return nil
        }

        let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return Credentials(
            accessToken: accessToken,
            expiresAtMilliseconds: (expiresAt ?? 0) > 0 ? expiresAt : nil,
            subscriptionType: oauth["subscriptionType"] as? String
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

private extension Data {
    init?(hexEncoded string: String) {
        let characters = Array(string)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
