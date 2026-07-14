import Foundation
import Darwin

enum ChatGPTQuotaService {
    static func fetch() async throws -> QuotaSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try fetchSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchSynchronously() throws -> QuotaSnapshot {
        guard let executable = executableURL() else {
            throw QuotaError.executableMissing
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw QuotaError.requestFailed("无法启动 ChatGPT/Codex 额度读取。")
        }

        let messages = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"quota_blocks","title":"Quota Blocks","version":"0.1.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":1,"params":{}}"#,
        ].joined(separator: "\n") + "\n"

        input.fileHandleForWriting.write(Data(messages.utf8))
        var pending = Data()
        let deadline = Date().addingTimeInterval(10)
        var descriptor = pollfd(
            fd: output.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )

        while Date() < deadline {
            let ready = poll(&descriptor, 1, 500)
            guard ready >= 0 else { break }
            guard ready > 0 else { continue }

            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                if let snapshot = try QuotaParsers.parseCodexLine(Data(line)) {
                    try? input.fileHandleForWriting.close()
                    process.terminate()
                    process.waitUntilExit()
                    return snapshot
                }
            }
        }

        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if errorText.localizedCaseInsensitiveContains("login") ||
            errorText.localizedCaseInsensitiveContains("authentication") {
            throw QuotaError.notSignedIn("ChatGPT")
        }
        throw QuotaError.invalidResponse("ChatGPT")
    }

    private static func executableURL() -> URL? {
        let manager = FileManager.default
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        return candidates
            .first(where: manager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}
