import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum AppLanguage: String {
        case chinese
        case english
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: 73)
    private let contentView = StatusContentView(frame: NSRect(x: 0, y: 0, width: 73, height: 22))
    private var chatGPTState: QuotaState = .loading
    private var claudeState: QuotaState = .loading
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var language: AppLanguage = {
        if let saved = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: saved)
        {
            return language
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        rebuildMenu()
        refresh()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 120,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        updateToolTip()
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = button.bounds
        button.addSubview(contentView)
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor in
            async let chatGPTResult = capture { try await ChatGPTQuotaService.fetch() }
            async let claudeResult = capture { try await ClaudeQuotaService.fetch() }
            let (chatGPT, claude) = await (chatGPTResult, claudeResult)

            chatGPTState = state(from: chatGPT)
            claudeState = state(from: claude)
            contentView.update(chatGPT: chatGPTState, claude: claudeState)
            statusItem.length = StatusContentView.preferredWidth(
                chatGPT: chatGPTState,
                claude: claudeState
            )
            isRefreshing = false
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Quota Blocks", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        addProviderSection(.chatGPT, state: chatGPTState, to: menu)
        menu.addItem(.separator())
        addProviderSection(.claude, state: claudeState, to: menu)
        menu.addItem(.separator())

        let languageItem = NSMenuItem(
            title: language == .chinese ? "切换为 English" : "Switch to 中文",
            action: #selector(toggleLanguage),
            keyEquivalent: ""
        )
        languageItem.target = self
        menu.addItem(languageItem)

        let openChatGPT = NSMenuItem(title: text("打开 ChatGPT 额度页面", "Open ChatGPT usage"), action: #selector(openChatGPTUsage), keyEquivalent: "")
        openChatGPT.target = self
        menu.addItem(openChatGPT)

        let openClaude = NSMenuItem(title: text("打开 Claude 额度页面", "Open Claude usage"), action: #selector(openClaudeUsage), keyEquivalent: "")
        openClaude.target = self
        menu.addItem(openClaude)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: text("退出 Quota Blocks", "Quit Quota Blocks"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addProviderSection(_ provider: QuotaProvider, state: QuotaState, to menu: NSMenu) {
        let heading = NSMenuItem(title: provider.rawValue, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        switch state {
        case .loading:
            menu.addItem(disabledItem("  \(text("正在读取…", "Loading…"))"))
        case let .available(snapshot):
            if provider == .claude {
                if let session = snapshot.session {
                    menu.addItem(windowItem(label: text("5 小时", "5-hour session"), window: session))
                }
                menu.addItem(windowItem(label: text("周额度", "Weekly"), window: snapshot.weekly))
                if let fable = snapshot.fable {
                    menu.addItem(windowItem(label: "Fable", window: fable))
                }
            } else {
                menu.addItem(windowItem(label: text("周额度", "Weekly"), window: snapshot.weekly))
            }
        case .unavailable:
            menu.addItem(disabledItem("  \(text("暂时无法读取，请确认已登录", "Unavailable — check that you’re signed in"))"))
        }
    }

    private func windowItem(label: String, window: QuotaWindow) -> NSMenuItem {
        let resetText = window.resetsAt.map { " · \(text("重置", "resets")) \(formatResetDate($0))" } ?? ""
        return disabledItem("  \(label) · \(text("剩余", "remaining")) \(window.remainingPercent)%\(resetText)")
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func text(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }

    private func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        formatter.dateFormat = language == .chinese ? "M月d日 E HH:mm" : "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private func updateToolTip() {
        statusItem.button?.toolTip = text("ChatGPT 与 Claude 周额度", "ChatGPT and Claude weekly quotas")
    }

    private func state(from result: Result<QuotaSnapshot, Error>) -> QuotaState {
        switch result {
        case let .success(snapshot): .available(snapshot)
        case let .failure(error): .unavailable(error.localizedDescription)
        }
    }

    @objc private func openChatGPTUsage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    @objc private func openClaudeUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleLanguage() {
        language = language == .chinese ? .english : .chinese
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        updateToolTip()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
