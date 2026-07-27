import Foundation

/// Asks Claude Code to refresh its own OAuth credentials when the stored
/// access token has expired.
///
/// Claude Code owns the rotating refresh token; refreshing it from a second
/// process desynchronizes the shared credentials and signs Claude Code out.
/// Quota Blocks therefore never calls the OAuth endpoint or writes credential
/// storage. Instead it runs the user's own `claude` CLI once with a model
/// name that cannot exist: Claude Code refreshes its expired access token
/// before sending the request, the request itself fails without consuming
/// any quota, and Quota Blocks simply re-reads what Claude Code wrote back.
actor ClaudeCodeRefreshTrigger {
    static let shared = ClaudeCodeRefreshTrigger()

    /// Minimum spacing between probe attempts so a broken login cannot make
    /// the app spawn `claude` on every 2-minute refresh cycle.
    static let attemptCooldown: TimeInterval = 600
    private static let probeTimeout: TimeInterval = 90
    /// Never a real model: the request fails before any tokens are consumed,
    /// but Claude Code still refreshes an expired access token first.
    private static let probeModel = "quota-blocks-refresh-probe"

    private var lastAttemptAt: Date?
    private var inFlight: Task<Bool, Never>?

    static func shouldAttempt(lastAttemptAt: Date?, now: Date) -> Bool {
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= attemptCooldown
    }

    /// Returns true when a probe actually ran; the caller re-reads the
    /// credential sources afterwards either way.
    func requestRefresh() async -> Bool {
        if let inFlight {
            return await inFlight.value
        }
        guard Self.shouldAttempt(lastAttemptAt: lastAttemptAt, now: Date()) else {
            return false
        }
        lastAttemptAt = Date()
        let probe = Task.detached(priority: .utility) { Self.runProbe() }
        inFlight = probe
        let didRun = await probe.value
        inFlight = nil
        return didRun
    }

    static func locateClaudeBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A stable, empty working directory so the probe never picks up project
    /// files and Claude Code records at most one project path for it.
    private static func probeWorkingDirectory() -> URL {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("com.nathanchengyi.QuotaBlocks/claude-probe", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func runProbe() -> Bool {
        guard let binary = locateClaudeBinary() else { return false }

        let process = Process()
        process.executableURL = binary
        // --no-session-persistence and an empty strict MCP config keep the
        // probe from leaving session files behind or starting MCP servers.
        process.arguments = [
            "-p",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--model", probeModel,
            "ok",
        ]
        process.currentDirectoryURL = probeWorkingDirectory()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(probeTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        // A non-zero exit is expected: the probe model does not exist. The
        // refresh side effect has already happened by the time the CLI exits.
        return true
    }
}
