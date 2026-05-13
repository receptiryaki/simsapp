import Cocoa

/// Modal sheet that creates a simulator via `simctl create`.
@MainActor
final class NewSimulatorSheetController: NSWindowController {

    typealias Completion = @MainActor (_ createdUDID: String?) -> Void

    private let nameField = NSTextField()
    private let runtimePopup = NSPopUpButton()
    private let deviceTypePopup = NSPopUpButton()
    private let createButton = NSButton()
    private let cancelButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    private var deviceTypes: [SimctlUtil.DeviceType] = []
    private var runtimes: [SimctlUtil.Runtime] = []
    private var completion: Completion?

    private let workQueue = DispatchQueue(label: "sims.newDevice", qos: .userInitiated)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "New Simulator"
        super.init(window: window)
        installForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(over parent: NSWindow, completion: @escaping Completion) {
        self.completion = completion
        guard let sheet = window else { completion(nil); return }
        parent.beginSheet(sheet) { _ in }
        loadLists()
    }

    // MARK: - layout

    private func installForm() {
        guard let contentView = window?.contentView else { return }

        nameField.placeholderString = "My iPhone"
        nameField.delegate = self

        runtimePopup.target = self
        runtimePopup.action = #selector(runtimeChanged(_:))

        configureButton(createButton, title: "Create", key: "\r", action: #selector(createClicked(_:)))
        createButton.isEnabled = false
        configureButton(cancelButton, title: "Cancel", key: "\u{1b}", action: #selector(cancelClicked(_:)))

        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Simulator Name:"), nameField],
            [NSTextField(labelWithString: "Device Type:"),    deviceTypePopup],
            [NSTextField(labelWithString: "OS Version:"),     runtimePopup],
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [progressIndicator, errorLabel, cancelButton, createButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.setHuggingPriority(.required, for: .horizontal)
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        contentView.addSubview(grid)
        contentView.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            deviceTypePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            runtimePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
        ])
    }

    private func configureButton(_ button: NSButton, title: String, key: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.target = self
        button.action = action
    }

    // MARK: - async work

    private func runOffMain<T>(
        _ work: @Sendable @escaping () throws -> T,
        then: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        workQueue.async {
            let result = Result(catching: work)
            Task { @MainActor in then(result) }
        }
    }

    private func loadLists() {
        setBusy(true)
        runOffMain {
            (types: try SimctlUtil.listDeviceTypes(), runtimes: try SimctlUtil.listRuntimes())
        } then: { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let lists):
                self.deviceTypes = lists.types
                self.runtimes = lists.runtimes.filter(\.isAvailable)
                self.populatePopups()
            case .failure(let error):
                self.errorLabel.stringValue = "\(error)"
            }
        }
    }

    private func populatePopups() {
        runtimePopup.removeAllItems()
        let sorted = runtimes.sorted { lhs, rhs in
            if lhs.platform != rhs.platform { return lhs.platform < rhs.platform }
            return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
        for rt in sorted {
            let item = NSMenuItem(title: rt.name, action: nil, keyEquivalent: "")
            item.representedObject = rt
            runtimePopup.menu?.addItem(item)
        }
        if let firstIOS = sorted.firstIndex(where: { $0.platform == "iOS" }) {
            runtimePopup.selectItem(at: firstIOS)
        }
        rebuildDeviceTypePopup()
    }

    private func rebuildDeviceTypePopup() {
        deviceTypePopup.removeAllItems()
        guard let runtime = selectedRuntime() else { return }
        let allowed = Set(runtime.supportedDeviceTypeIds)
        let filtered = deviceTypes
            .filter { allowed.contains($0.identifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for dt in filtered {
            let item = NSMenuItem(title: dt.name, action: nil, keyEquivalent: "")
            item.representedObject = dt
            deviceTypePopup.menu?.addItem(item)
        }
        if filtered.isEmpty {
            deviceTypePopup.addItem(withTitle: "No compatible devices")
            deviceTypePopup.isEnabled = false
        } else {
            deviceTypePopup.isEnabled = true
        }
        updateCreateEnabled()
    }

    // MARK: - state

    private func selectedRuntime() -> SimctlUtil.Runtime? {
        runtimePopup.selectedItem?.representedObject as? SimctlUtil.Runtime
    }

    private func selectedDeviceType() -> SimctlUtil.DeviceType? {
        deviceTypePopup.selectedItem?.representedObject as? SimctlUtil.DeviceType
    }

    private func updateCreateEnabled() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        createButton.isEnabled = !name.isEmpty
            && selectedDeviceType() != nil
            && selectedRuntime() != nil
    }

    private func setBusy(_ busy: Bool) {
        if busy { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
        nameField.isEnabled = !busy
        runtimePopup.isEnabled = !busy
        deviceTypePopup.isEnabled = !busy && deviceTypePopup.numberOfItems > 0
        cancelButton.isEnabled = !busy
        if busy {
            createButton.isEnabled = false
        } else {
            updateCreateEnabled()
        }
    }

    // MARK: - actions

    @objc private func runtimeChanged(_ sender: Any?) { rebuildDeviceTypePopup() }
    @objc private func cancelClicked(_ sender: Any?) { finish(udid: nil) }

    @objc private func createClicked(_ sender: Any?) {
        guard let dt = selectedDeviceType(), let rt = selectedRuntime() else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        errorLabel.stringValue = ""
        setBusy(true)

        let dtId = dt.identifier, rtId = rt.identifier
        runOffMain {
            try SimctlUtil.createDevice(name: name, deviceTypeId: dtId, runtimeId: rtId)
        } then: { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let udid): self.finish(udid: udid)
            case .failure(let error): self.errorLabel.stringValue = "\(error)"
            }
        }
    }

    private func finish(udid: String?) {
        let cb = completion
        completion = nil
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        cb?(udid)
    }
}

extension NewSimulatorSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateCreateEnabled() }
}

private extension SimctlUtil.Runtime {
    /// Coarse platform label parsed from the runtime identifier — used
    /// only for popup sort grouping.
    var platform: String {
        let last = identifier.split(separator: ".").last ?? ""
        return String(last.split(separator: "-").first ?? "")
    }
}
