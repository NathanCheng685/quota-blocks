import AppKit

final class StatusContentView: NSView {
    private static let valueX: CGFloat = 51
    private static let outerPadding: CGFloat = 1
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private static let minimumValueWidth = ("88%" as NSString).size(
        withAttributes: [.font: valueFont]
    ).width

    private var chatGPTState: QuotaState = .loading
    private var claudeState: QuotaState = .loading

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(chatGPT: QuotaState, claude: QuotaState) {
        chatGPTState = chatGPT
        claudeState = claude
        needsDisplay = true
    }

    static func preferredWidth(chatGPT: QuotaState, claude: QuotaState) -> CGFloat {
        let widestValue = [chatGPT, claude]
            .map(valueText)
            .map { ($0 as NSString).size(withAttributes: [.font: valueFont]).width }
            .max() ?? minimumValueWidth
        return ceil(valueX + max(minimumValueWidth, widestValue) + outerPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRow(provider: .chatGPT, state: chatGPTState, y: 1)
        drawRow(provider: .claude, state: claudeState, y: 12)
    }

    private func drawRow(provider: QuotaProvider, state: QuotaState, y: CGFloat) {
        drawIcon(provider: provider, rect: NSRect(x: 1, y: y + 1, width: 9, height: 9))

        let color = providerColor(provider)
        let filledCount: Int
        if case let .available(snapshot) = state {
            filledCount = snapshot.filledBlockCount
        } else {
            filledCount = 0
        }

        let blockWidth: CGFloat = 5
        let blockHeight: CGFloat = 7
        let gap: CGFloat = 2
        let blockStartX: CGFloat = 14
        for index in 0..<5 {
            let rect = NSRect(
                x: blockStartX + CGFloat(index) * (blockWidth + gap),
                y: y + 2,
                width: blockWidth,
                height: blockHeight
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            if index < filledCount {
                color.setFill()
            } else {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
            }
            path.fill()
        }

        let value = Self.valueText(state)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.valueFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let valueRect = NSRect(
            x: Self.valueX,
            y: y,
            width: max(0, bounds.width - Self.valueX - Self.outerPadding),
            height: 11
        )
        value.draw(in: valueRect, withAttributes: attributes)
    }

    private static func valueText(_ state: QuotaState) -> String {
        switch state {
        case .loading: "···"
        case let .available(snapshot): "\(snapshot.remainingPercent)%"
        case .unavailable: "—"
        }
    }

    private func drawIcon(provider: QuotaProvider, rect: NSRect) {
        let name = provider == .chatGPT ? "chatgpt" : "claude"
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func providerColor(_ provider: QuotaProvider) -> NSColor {
        switch provider {
        case .chatGPT:
            NSColor(red: 0.063, green: 0.639, blue: 0.498, alpha: 1)
        case .claude:
            NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        }
    }
}
