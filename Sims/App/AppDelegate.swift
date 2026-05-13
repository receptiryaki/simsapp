import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var simulators: (any Simulators)?
    private var controllers: [SimulatorTabController] = []
    /// The window subsequent tabs join via `addTabbedWindow`. Tracks
    /// the most-recently-opened tab; if it goes away, we use any
    /// remaining controller as the next anchor.
    private weak var anchorWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable system-managed tabbing before any NSWindow exists.
        NSWindow.allowsAutomaticWindowTabbing = true

        installMainMenu()
        let sims = CoreSimulators()
        simulators = sims

        let initial = makeController(sims: sims)
        initial.showWindow(nil)
        anchorWindow = initial.window
        forceTabBarVisible(initial.window)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: tab lifecycle

    /// Spawn a new picker-mode tab and join it to the existing window
    /// group. Wired to `newWindowForTab(_:)` via the responder chain,
    /// which is what the AppKit "+" button on the tab bar and the
    /// File → New Tab menu item both call.
    @MainActor
    func openNewTab() {
        guard let sims = simulators else { return }
        let controller = makeController(sims: sims)
        guard let newWindow = controller.window else { return }
        if let anchor = anchorWindow, anchor !== newWindow {
            anchor.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        anchorWindow = newWindow
        forceTabBarVisible(newWindow)
    }

    /// AppKit auto-hides the tab bar when only one tab remains. We
    /// want it persistently visible so the "+" button and tab switcher
    /// are always one click away. `toggleTabBar(_:)` is the public
    /// equivalent of View → Show Tab Bar; we call it after layout
    /// settles on the main queue because `tabGroup` isn't always
    /// populated synchronously right after `showWindow`.
    private func forceTabBarVisible(_ window: NSWindow?) {
        guard let window else { return }
        DispatchQueue.main.async {
            if window.tabGroup?.isTabBarVisible == false {
                window.toggleTabBar(nil)
            }
        }
    }

    private func makeController(sims: any Simulators) -> SimulatorTabController {
        let c = SimulatorTabController(simulators: sims) { [weak self] in
            self?.openNewTab()
        }
        c.onClose = { [weak self] closed in
            guard let self else { return }
            controllers.removeAll { $0 === closed }
            // If the anchor just went away, point at any surviving
            // controller so the next openNewTab still tabs into the
            // active group.
            if anchorWindow === closed.window {
                anchorWindow = controllers.last?.window
            }
            // Closing the second-to-last tab is exactly when AppKit
            // re-hides the tab bar; force it back on so the surviving
            // tab still shows the strip + "+" button.
            forceTabBarVisible(anchorWindow)
        }
        controllers.append(c)
        return c
    }

    // MARK: menu

    /// Programmatic main menu — no NIB, no storyboard.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (Sims)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Sims")
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "About Sims",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        let hide = NSMenuItem(
            title: "Hide Sims",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Sims",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // File menu — New Tab + Close Tab
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        // The action goes through the responder chain to
        // SimulatorTabController.newWindowForTab(_:) (the active tab's
        // controller), which calls back into AppDelegate.openNewTab().
        fileMenu.addItem(NSMenuItem(
            title: "New Tab",
            action: #selector(NSWindow.newWindowForTab(_:)),
            keyEquivalent: "t"
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Close Tab",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))

        NSApp.mainMenu = mainMenu
    }
}
