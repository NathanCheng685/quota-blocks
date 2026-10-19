import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--launch-at-login-status") {
    let status: String
    switch SMAppService.mainApp.status {
    case .notRegistered: status = "not registered"
    case .enabled: status = "enabled"
    case .requiresApproval: status = "requires approval"
    case .notFound: status = "not found"
    @unknown default: status = "unknown"
    }
    print("Launch at login: \(status)")
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try QuotaSelfTest.run()
        print("Quota Blocks self-test passed")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Quota Blocks self-test failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--probe-credentials") {
    Task {
        print(await ClaudeQuotaService.credentialDiagnostics())
        exit(EXIT_SUCCESS)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--probe-live") {
    Task {
        do {
            let chatGPT = try await ChatGPTQuotaService.fetch()
            print("ChatGPT remaining: \(chatGPT.remainingPercent)%\(chatGPT.plan.map { " · plan \($0)" } ?? "")")
            if let session = chatGPT.session {
                print("ChatGPT 5-hour remaining: \(session.remainingPercent)% · resets \(session.resetsAt?.description ?? "unknown")")
            }
        } catch {
            print("ChatGPT error: \(error.localizedDescription)")
        }
        do {
            let claude = try await ClaudeQuotaService.fetch()
            print("Claude weekly remaining: \(claude.remainingPercent)%\(claude.plan.map { " · plan \($0)" } ?? "")")
            if let session = claude.session {
                print("Claude 5-hour remaining: \(session.remainingPercent)%")
            }
            if let fable = claude.fable {
                print("Claude Fable remaining: \(fable.remainingPercent)%")
            }
            print("Claude Code version for usage requests: \(ClaudeCodeVersion.installed() ?? "unknown")")
            if claude.resetGrants.isEmpty {
                print("Claude limit resets: none")
            }
            for grant in claude.resetGrants {
                print("Claude limit reset: \(grant.resetsLeft) left · until \(grant.endsAt?.description ?? "no deadline") · \(grant.label)")
            }
        } catch {
            print("Claude error: \(error.localizedDescription)")
        }
        exit(EXIT_SUCCESS)
    }
    dispatchMain()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
