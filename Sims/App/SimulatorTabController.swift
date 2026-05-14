import Cocoa
import IOSurface

/// One tab in the Sims window. Each tab is independent and lives in
/// one of two modes:
///
///   `.picker`    — `NSTableView` of every simulator the host has, with
///                  per-row Boot / Shutdown buttons. Default for a new
///                  tab.
///   `.streaming` — `StreamView` rendering the simulator's framebuffer,
///                  with a toolbar `Stop` button that returns to picker
///                  mode.
///
/// Double-click a Booted row → enter streaming mode for that simulator.
/// Toolbar Stop → tear down the stream and re-enter picker mode in the
/// same tab. Tabs are joined to a common `tabbingIdentifier` group so
/// AppKit's native tab bar renders across the window.
@MainActor
final class SimulatorTabController: NSWindowController, NSWindowDelegate {

    enum Mode {
        case picker
        case streaming(simulator: any Simulator, screen: any Screen, input: any Input)
    }

    private let simulators: any Simulators
    private let onNewTab: @MainActor () -> Void

    private var mode: Mode = .picker

    // MARK: picker views

    private let pickerContainer = NSView()
    /// Vertical stack of `SimulatorRowView`s rebuilt on each refresh.
    /// Each card carries an icon, title, UDID subtitle, state indicator,
    /// and the Boot / Shutdown buttons.
    private let listStack = NSStackView()
    private var rows: [any Simulator] = []
    // Timer is thread-confined; `nonisolated(unsafe)` lets `deinit`
    // invalidate it without tripping Swift 6's nonisolated-deinit /
    // non-Sendable-property check.
    nonisolated(unsafe) private var refreshTimer: Timer?

    // MARK: streaming views

    private let streamView = StreamView(frame: .zero)

    /// Serial queue for blocking simctl invocations (Screenshot) and
    /// HID dispatch from toolbar actions. Keeps the main run loop free
    /// of fork/exec and dlopen.
    private let toolQueue = DispatchQueue(label: "sims.toolbar", qos: .userInitiated)

    // MARK: toolbar
    //
    // The toolbar bar is permanently attached (constant titlebar height
    // across mode switches) but currently has zero items. Future
    // streaming-mode controls — Home, Lock, screenshot, etc. — will go
    // here. Add the identifier to `toolbarAllowedItemIdentifiers`, build
    // the item in `toolbar(_:itemForItemIdentifier:...)`, and call
    // `toolbar.insertItem(...)` from `enterStreamMode` / removeItem from
    // `enterPickerMode`.

    /// Fires on `windowWillClose` so AppDelegate can drop this
    /// controller from its list.
    var onClose: (@MainActor (SimulatorTabController) -> Void)?

    /// Set by the close-prompt sheet's completion handler to short-
    /// circuit `windowShouldClose` on the re-entry from `sender.close()`.
    private var pendingCloseAccepted = false

    init(simulators: any Simulators, onNewTab: @MainActor @escaping () -> Void) {
        self.simulators = simulators
        self.onNewTab = onNewTab

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Select Simulator"
        window.center()
        window.contentMinSize = NSSize(width: 360, height: 280)
        // Shared tabbing identifier so every tab joins the same group.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "sims"
        super.init(window: window)
        window.delegate = self
        installToolbar()
        installContent()
        enterPickerMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: setup

    private func installToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "SimsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        // `.unifiedCompact` shrinks the toolbar's vertical area; combined
        // with `.iconOnly` and a small SymbolConfiguration on each item,
        // gives us a tight icon-only toolbar.
        window.toolbarStyle = .unifiedCompact
    }

    private func installContent() {
        guard let contentView = window?.contentView else { return }

        pickerContainer.translatesAutoresizingMaskIntoConstraints = false
        streamView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(pickerContainer)
        contentView.addSubview(streamView)
        streamView.isHidden = true

        for view in [pickerContainer as NSView, streamView as NSView] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        installPickerList(in: pickerContainer)
    }

    private func installPickerList(in container: NSView) {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.distribution = .fill
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // Wrap the stack in a flipped content view so we can pin width
        // to the scroll view's clip view AND the rows hug the top of
        // the scroll area. AppKit's default bottom-up coordinate system
        // would otherwise park the documentView against the bottom of
        // the clip view whenever the list is shorter than the window.
        let stackContainer = FlippedView()
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        stackContainer.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: stackContainer.topAnchor, constant: 12),
            listStack.leadingAnchor.constraint(equalTo: stackContainer.leadingAnchor, constant: 16),
            listStack.trailingAnchor.constraint(equalTo: stackContainer.trailingAnchor, constant: -16),
            listStack.bottomAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: -12),
        ])

        scroll.documentView = stackContainer
        if let clip = scroll.contentView as NSClipView? {
            stackContainer.widthAnchor.constraint(equalTo: clip.widthAnchor).isActive = true
        }

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: mode transitions

    /// Tear down any active stream and show the picker table.
    private func enterPickerMode() {
        if case .streaming(_, let screen, _) = mode { screen.stop() }
        mode = .picker
        window?.title = "Select Simulator"
        removeStreamToolbarItems()

        pickerContainer.isHidden = false
        streamView.isHidden = true

        startRefreshTimer()
        refresh()
    }

    /// Switch this tab to streaming the given simulator. The simulator
    /// must already be Booted — the picker enforces this by gating
    /// double-click on `sim.state == .booted`.
    private func enterStreamMode(for sim: any Simulator) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let screen = sim.screen()
        let input = sim.input()
        mode = .streaming(simulator: sim, screen: screen, input: input)

        window?.title = sim.name
        insertStreamToolbarItems()
        pickerContainer.isHidden = true
        streamView.isHidden = false
        streamView.attachInput(input)
        window?.makeFirstResponder(streamView)

        do {
            try screen.start { [weak self] surface in
                let frame = FrameBox(surface: surface)
                Task { @MainActor in
                    self?.streamView.display(frame.surface)
                }
            }
        } catch {
            logErr("stream start \(sim.udid): \(error)")
        }
    }

    // MARK: dynamic toolbar items

    /// Insert all streaming-mode tools, in spec order, at slot 0.
    /// Inserting in reverse so the visible left-to-right order matches.
    private func insertStreamToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        for id in Self.streamItemIdentifiers.reversed() {
            if !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
                toolbar.insertItem(withItemIdentifier: id, at: 0)
            }
        }
    }

    private func removeStreamToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        // Walk indices in reverse so removals don't reshuffle prior ones.
        for index in toolbar.items.indices.reversed() {
            let id = toolbar.items[index].itemIdentifier
            if Self.streamItemIdentifiers.contains(id) {
                toolbar.removeItem(at: index)
            }
        }
    }

    /// The toolbar items SimulatorTabController owns in streaming mode,
    /// in visible left-to-right order. Rotate / Paste / Toggle Keyboard
    /// were tried and removed — Rotate's GSEvent path didn't reliably
    /// drive UIKit's rotation; Paste was redundant with iOS's own
    /// pasteboard sync; Toggle Keyboard has no public toggle path.
    private static let streamItemIdentifiers: [NSToolbarItem.Identifier] = [
        .home, .screenshot, .volumeGroup
    ]

    // MARK: toolbar actions

    @objc func goHomeAction(_ sender: Any?) {
        guard case .streaming(_, _, let input) = mode else { return }
        toolQueue.async {
            _ = input.button(.home, duration: 0)
        }
    }

    @objc func screenshotAction(_ sender: Any?) {
        guard case .streaming(let sim, _, _) = mode else { return }
        let udid = sim.udid
        let name = sim.name
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let filename = "Sims \(safeName) \(formatter.string(from: Date())).png"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)
        toolQueue.async {
            do {
                try SimctlUtil.screenshot(udid: udid, to: url)
                // Reveal the file in Finder so the user notices.
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                logErr("screenshot \(udid): \(error)")
            }
        }
    }

    @objc func volumeUpAction(_ sender: Any?) {
        guard case .streaming(_, _, let input) = mode else { return }
        toolQueue.async { _ = input.button(.volumeUp, duration: 0) }
    }

    @objc func volumeDownAction(_ sender: Any?) {
        guard case .streaming(_, _, let input) = mode else { return }
        toolQueue.async { _ = input.button(.volumeDown, duration: 0) }
    }

    // MARK: new tab (Cmd-T / "+" on the tab bar / File menu)

    /// AppKit's responder-chain hook for "+ on tab bar" / Cmd-T / the
    /// `NSWindow.newWindowForTab(_:)` selector emitted by AppKit's
    /// default menu wiring. Defined on NSResponder in modern AppKit,
    /// hence the `override`.
    override func newWindowForTab(_ sender: Any?) {
        onNewTab()
    }

    // MARK: refresh loop (picker mode only)

    private func startRefreshTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        refreshTimer = timer
    }

    private func refresh() {
        guard case .picker = mode else { return }
        let aggregate = simulators
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .userInitiated) {
                aggregate.all
            }.value
            self?.apply(fresh)
        }
    }

    /// Rebuild the picker list with `fresh`. Rows are recreated rather
    /// than diffed — the list is short (typically ≤ 30 simulators) and
    /// refresh fires only once a second, so the simplicity wins over a
    /// per-row identity tracker.
    private func apply(_ fresh: [any Simulator]) {
        rows = fresh
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, sim) in fresh.enumerated() {
            let row = SimulatorRowView(simulator: sim)
            row.onBoot     = { [weak self] s in self?.bootSimulator(s) }
            row.onShutdown = { [weak self] s in self?.shutdownSimulator(s) }
            row.onActivate = { [weak self] s in self?.activateSimulator(s) }
            listStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
            if index < fresh.count - 1 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                listStack.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
                divider.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
    }

    // MARK: row actions

    private func bootSimulator(_ sim: any Simulator) {
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                do { try sim.boot() } catch {
                    logErr("boot \(sim.udid): \(error)")
                }
            }.value
            self?.refresh()
        }
    }

    private func shutdownSimulator(_ sim: any Simulator) {
        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                do { try sim.shutdown() } catch {
                    logErr("shutdown \(sim.udid): \(error)")
                }
            }.value
            self?.refresh()
        }
    }

    private func activateSimulator(_ sim: any Simulator) {
        guard sim.state == .booted else { return }
        enterStreamMode(for: sim)
    }

    // MARK: NSWindowDelegate

    /// Picker tabs close immediately. Streaming tabs surface a sheet
    /// first: shut down the sim, just close the tab (sim stays booted),
    /// or cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if pendingCloseAccepted { return true }
        guard case .streaming(let sim, _, _) = mode else { return true }

        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText =
            "“\(sim.name)” is still booted. Just close this tab, or shut down the simulator too?"
        // Order matters: first button is the rightmost / default (Return),
        // and a button titled "Cancel" auto-binds to Escape.
        alert.addButton(withTitle: "Just Close Tab")          // .alertFirstButtonReturn
        alert.addButton(withTitle: "Shut Down Simulator")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                  // .alertThirdButtonReturn

        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.pendingCloseAccepted = true
                sender.close()
            case .alertSecondButtonReturn:
                self.pendingCloseAccepted = true
                let target = sim
                Task.detached(priority: .userInitiated) {
                    do { try target.shutdown() } catch {
                        logErr("shutdown \(target.udid): \(error)")
                    }
                }
                sender.close()
            default:
                break   // Cancel — keep the tab open
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if case .streaming(_, let screen, _) = mode { screen.stop() }
        onClose?(self)
    }
}

// MARK: - SimulatorRowView

/// One card in the picker list. Carries an SF Symbol matching the
/// device class, a "{name} — {runtime}" title, a UDID subtitle, the
/// current state shown as a coloured dot + label, and the Boot /
/// Shutdown buttons. Double-clicking anywhere on a Booted row
/// activates streaming via the `onActivate` callback.
@MainActor
private final class SimulatorRowView: NSView {

    private var sim: any Simulator

    var onBoot: ((any Simulator) -> Void)?
    var onShutdown: ((any Simulator) -> Void)?
    var onActivate: ((any Simulator) -> Void)?

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let udidField  = NSTextField(labelWithString: "")
    private let stateDot   = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let bootButton = NSButton(title: "Boot", target: nil, action: nil)
    private let shutdownButton = NSButton(title: "Shutdown", target: nil, action: nil)

    init(simulator: any Simulator) {
        self.sim = simulator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupSubviews()
        refresh()

        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        dbl.numberOfClicksRequired = 2
        addGestureRecognizer(dbl)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupSubviews() {
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .regular, scale: .medium)
        iconView.contentTintColor = .systemBlue
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Let the text truncate when the window is narrow rather than
        // pushing the right-hand state + buttons cluster off-screen.
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        udidField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        udidField.textColor = .secondaryLabelColor
        udidField.lineBreakMode = .byTruncatingTail
        udidField.translatesAutoresizingMaskIntoConstraints = false
        udidField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateDot.symbolConfiguration = .init(pointSize: 9, weight: .black)
        stateDot.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        bootButton.bezelStyle = .rounded
        bootButton.controlSize = .small
        bootButton.target = self
        bootButton.action = #selector(handleBoot)
        bootButton.translatesAutoresizingMaskIntoConstraints = false

        shutdownButton.bezelStyle = .rounded
        shutdownButton.controlSize = .small
        shutdownButton.target = self
        shutdownButton.action = #selector(handleShutdown)
        shutdownButton.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleField, udidField])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let stateStack = NSStackView(views: [stateDot, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 4
        stateStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleStack)
        addSubview(stateStack)
        addSubview(bootButton)
        addSubview(shutdownButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: stateStack.leadingAnchor, constant: -12),

            stateStack.trailingAnchor.constraint(equalTo: bootButton.leadingAnchor, constant: -12),
            stateStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            bootButton.trailingAnchor.constraint(equalTo: shutdownButton.leadingAnchor, constant: -6),
            bootButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            shutdownButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shutdownButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func refresh() {
        iconView.image = NSImage(
            systemSymbolName: Self.symbolName(for: sim.deviceTypeName),
            accessibilityDescription: nil
        )
        let runtime = sim.runtime.isEmpty ? "" : " — \(sim.runtime)"
        titleField.stringValue = "\(sim.name)\(runtime)"
        udidField.stringValue  = sim.udid
        let (color, text) = Self.stateInfo(sim.state)
        stateDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        stateDot.contentTintColor = color
        stateLabel.stringValue = text
        bootButton.isEnabled     = sim.canBoot
        shutdownButton.isEnabled = sim.canShutdown
    }

    /// Map the stable CoreSimulator device-type name (e.g.
    /// `"iPhone 17 Pro Max"`, `"Apple Watch Series 10 (46mm)"`) to an SF
    /// Symbol. Match by lowercased substring so renamed sims and new
    /// model variants keep working without an exhaustive table.
    private static func symbolName(for deviceType: String) -> String {
        let l = deviceType.lowercased()
        if l.contains("ipad")     { return "ipad" }
        if l.contains("iphone")   { return "iphone" }
        if l.contains("watch")    { return "applewatch" }
        if l.contains("vision")   { return "visionpro" }
        if l.contains("tv")       { return "appletv" }
        if l.contains("homepod")  { return "homepod" }
        if l.contains("mac")      { return "laptopcomputer" }
        return "rectangle.on.rectangle"
    }

    private static func stateInfo(_ state: SimulatorState) -> (NSColor, String) {
        switch state {
        case .booted:        return (.systemGreen,  "Booted")
        case .booting:       return (.systemOrange, "Booting")
        case .shuttingDown:  return (.systemOrange, "Shutting Down")
        case .shutdown:      return (.tertiaryLabelColor, "Shutdown")
        case .creating:      return (.tertiaryLabelColor, "Creating")
        }
    }

    @objc private func handleBoot() {
        onBoot?(sim)
    }

    @objc private func handleShutdown() {
        onShutdown?(sim)
    }

    @objc private func handleDoubleClick() {
        onActivate?(sim)
    }
}

// MARK: - NSToolbarDelegate

extension SimulatorTabController: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .home:
            return makeItem(
                identifier: itemIdentifier,
                label: "Home", symbol: "house.fill",
                action: #selector(goHomeAction(_:))
            )
        case .screenshot:
            return makeItem(
                identifier: itemIdentifier,
                label: "Screenshot", symbol: "camera.fill",
                action: #selector(screenshotAction(_:))
            )
        case .volumeGroup:
            return makeVolumeGroup()
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.streamItemIdentifiers
    }

    // MARK: helpers

    private func makeItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(scale: .small))
        item.target = self
        item.action = action
        item.isEnabled = true
        return item
    }

    /// Two volume buttons in a single visually-grouped toolbar slot.
    /// Each subitem fires its own action; the group exists for layout.
    private func makeVolumeGroup() -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: .volumeGroup)
        group.label = "Volume"
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary

        let up = NSToolbarItem(itemIdentifier: .volumeUp)
        up.label = "Volume Up"
        up.toolTip = "Volume Up"
        up.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                           accessibilityDescription: "Volume Up")?
            .withSymbolConfiguration(.init(scale: .small))
        up.target = self
        up.action = #selector(volumeUpAction(_:))

        let down = NSToolbarItem(itemIdentifier: .volumeDown)
        down.label = "Volume Down"
        down.toolTip = "Volume Down"
        down.image = NSImage(systemSymbolName: "speaker.wave.1.fill",
                             accessibilityDescription: "Volume Down")?
            .withSymbolConfiguration(.init(scale: .small))
        down.target = self
        down.action = #selector(volumeDownAction(_:))

        group.subitems = [up, down]
        return group
    }
}

extension NSToolbarItem.Identifier {
    static let home        = NSToolbarItem.Identifier("sims.home")
    static let screenshot  = NSToolbarItem.Identifier("sims.screenshot")
    static let volumeGroup = NSToolbarItem.Identifier("sims.volumeGroup")
    static let volumeUp    = NSToolbarItem.Identifier("sims.volumeUp")
    static let volumeDown  = NSToolbarItem.Identifier("sims.volumeDown")
}

/// IOSurface transfer wrapper for the background-queue → MainActor hop
/// in `enterStreamMode`. IOSurface is documented thread-safe; the
/// Swift 6 strict-concurrency checker doesn't know that.
private struct FrameBox: @unchecked Sendable {
    let surface: IOSurface
}

/// Document container for the picker `NSScrollView`. `isFlipped`
/// returning true flips the coordinate system to top-left origin so
/// the scroll view positions content against the top of the clip
/// view, not the bottom (AppKit's default for bottom-up coords).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
