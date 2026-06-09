import Cocoa

/// Single-window preferences UI. Programmatic — no NIB. Bound to
/// `Settings.shared`; changes write through immediately.
@MainActor
final class SettingsWindowController: NSWindowController {

    private let touchRingCheckbox = NSButton()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        installContent()
        refreshFromSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installContent() {
        guard let contentView = window?.contentView else { return }

        touchRingCheckbox.setButtonType(.switch)
        touchRingCheckbox.title = "Show touch ring during interactions"
        touchRingCheckbox.target = self
        touchRingCheckbox.action = #selector(touchRingChanged(_:))

        let hint = NSTextField(labelWithString:
            "Disable to keep screen recordings clean — the ring won't appear in the captured video.")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 360

        let stack = NSStackView(views: [touchRingCheckbox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hint.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    private func refreshFromSettings() {
        touchRingCheckbox.state = Settings.shared.showTouchRing ? .on : .off
    }

    @objc private func touchRingChanged(_ sender: NSButton) {
        Settings.shared.showTouchRing = (sender.state == .on)
    }
}
