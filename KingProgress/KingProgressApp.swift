import AppKit
import Sparkle
import SwiftUI

@main
struct KingProgressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app lives in the status bar (see AppDelegate) and opens its
        // windows from code. A Settings scene is the smallest scene there is.
        Settings {
            EmptyView()
        }
    }
}

/// Owns the status item, the main window and the floating cards.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    private(set) lazy var monitor = RunMonitor(settings: settings)
    let clipboard = ClipboardWatcher()

    /// Sparkle: checks the appcast every six hours, downloads a newer build in
    /// the background and installs it on quit (or on "Restart to update").
    let updates = UpdateController()

    private var statusItem: NSStatusItem!
    private var mainWindow: MainWindow?
    private let fitter = WindowFitter()
    private lazy var popup = PopupController(monitor: monitor) { [weak self] url in self?.openGitHub(url) }
    private var snapshotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        monitor.onActionsChanged = { [weak self] in self?.syncPopup() }
        monitor.onTokenRevoked = { [weak self] in self?.showMainWindow() }

        // Re-apply every launch, not just the first: an update, a move to a
        // different folder or a login item the user removed by hand all
        // leave the OS out of step with what the setting says.
        applyOpenAtLogin()

        let environment = ProcessInfo.processInfo.environment

        if let path = environment["KINGPROGRESS_SNAPSHOT"] {
            snapshot(kind: environment["KINGPROGRESS_SNAPSHOT_KIND"] ?? "window", to: path)
            return
        }

        if environment["KINGPROGRESS_DEBUG"] != nil {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let frame = self.statusItem.button?.window?.frame ?? .zero
                    self.log("status item frame: \(frame) visible: \(self.statusItem.isVisible); main window: \(self.mainWindow.map { "\($0.frame) visible \($0.isVisible)" } ?? "none"); \(self.popup.debugDescription)")
                }
            }
        }

        if environment["KINGPROGRESS_DEMO"] == "1" {
            log("demo mode")
            monitor.startDemo()
            return
        }

        monitor.start()

        if !monitor.isSignedIn {
            log("not signed in yet - opening the window")
            showMainWindow()
        }
    }

    /// Finder double-click (or `open -a KingProgress`) while it already runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        clipboard.stop()
        popup.hide()
    }

    // MARK: - Status item

    private func installStatusItem() {
        // A new status item lands at the far left of the third-party items,
        // which on a MacBook is under the notch. macOS keeps the position per
        // autosave name in UserDefaults, measured from the right edge; seeding
        // a small value once puts the item next to the system icons. Dragging
        // it (with the command key) still wins afterwards.
        //
        // The Electron version shared this bundle id and left its own position
        // behind under AppKit's automatic name, so the icon stays exactly
        // where it was.
        let positionKey = "NSStatusItem Preferred Position KingProgress"
        if !UserDefaults.standard.bool(forKey: "seededStatusItemPosition") {
            let inherited = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position Item-0")
            UserDefaults.standard.set(inherited ?? 1, forKey: positionKey)
            UserDefaults.standard.set(true, forKey: "seededStatusItemPosition")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "KingProgress"

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "KingProgress - GitHub Actions Monitor"
            button.target = self
            button.action = #selector(statusItemClicked)
            // A left click opens the window; a right click shows the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            showMainWindow()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Show Window", action: #selector(showWindowAction), keyEquivalent: "").target = self

        // An update that is on its way, or waiting for a restart, is worth a
        // line here - this menu is the only part of KingProgress that is
        // always reachable.
        switch updates.model.status {
        case .ready:
            menu.addItem(withTitle: "Restart to update to \(updates.model.newVersion ?? "")", action: #selector(installUpdateAction), keyEquivalent: "").target = self
        case .downloading:
            menu.addItem(withTitle: "Downloading \(updates.model.newVersion ?? "the update")…", action: nil, keyEquivalent: "")
        default:
            break
        }

        if monitor.isSignedIn {
            menu.addItem(withTitle: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KingProgress", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Attach the menu just long enough to pop it up, so a plain left
        // click keeps opening the window.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showWindowAction() {
        showMainWindow()
    }

    @objc private func installUpdateAction() {
        updates.installUpdate()
    }

    @objc private func disconnectAction() {
        monitor.signOut()
        popup.hide()
    }

    // MARK: - Main window

    private func showMainWindow() {
        if mainWindow == nil {
            let window = MainWindow()
            fitter.window = window
            window.delegate = self
            // The content reports its height and the fitter sizes the window.
            embed(RootView(
                monitor: monitor,
                updates: updates,
                clipboard: clipboard,
                openURL: { [weak self] url in self?.openGitHub(url) },
                fit: { [weak self] height in self?.fitter.fit(height: height) }
            ), in: window)
            if !window.setFrameUsingName("KingProgressMain") {
                window.center()
            }
            mainWindow = window
        }

        // Show the dock icon while the window is open, like any window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        syncPopup()
    }

    private var mainWindowIsShowing: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible && !mainWindow.isMiniaturized
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        clipboard.stop()
        mainWindow = nil
        fitter.window = nil
        NSApp.setActivationPolicy(.accessory)
        syncPopup()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        syncPopup()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        syncPopup()
    }

    // MARK: - Cards

    /// The window and the cards show the same runs, so having both on screen
    /// is just the same information twice. The window wins while it is open.
    private func syncPopup() {
        if mainWindowIsShowing {
            popup.hide()
        } else if !monitor.actions.isEmpty {
            popup.show()
        } else {
            popup.hideWhenSettled()
        }
    }

    /// Only ever opens GitHub, so a card can never send us anywhere else.
    private func openGitHub(_ url: URL) {
        guard url.absoluteString.hasPrefix("https://github.com/") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Start at login

    private func applyOpenAtLogin() {
        guard LaunchAtLogin.isInstalled else {
            return
        }
        do {
            try LaunchAtLogin.set(settings.openAtLogin)
        } catch {
            log("could not change the start-at-login setting: \(error.localizedDescription)")
        }
    }

    // MARK: - Snapshot

    /// Development aid: `KINGPROGRESS_SNAPSHOT=/tmp/window.png KingProgress`
    /// renders a view into a window, writes it to that path and quits, which
    /// is how the screenshots in the README are made. Screen recording
    /// permission is not needed, which a screenshot would be.
    /// `KINGPROGRESS_SNAPSHOT_KIND` picks window (default), settings, login or popup.
    private func snapshot(kind: String, to path: String) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        monitor.startDemo(account: Account(login: "octocat", name: "The Octocat", avatarUrl: "", scopes: ["repo", "workflow"]))

        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: MainView.width, height: 10), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Theme.bg)
        window.appearance = NSAppearance(named: .darkAqua)
        fitter.window = window

        let openURL: (URL) -> Void = { _ in }
        let fit: (CGFloat) -> Void = { [weak self] height in self?.fitter.fit(height: height) }

        let root: AnyView
        switch kind {
        case "login":
            root = AnyView(LoginView(monitor: monitor, clipboard: clipboard, openURL: openURL, fit: fit))
        case "settings":
            root = AnyView(MainView(monitor: monitor, updates: updates, openURL: openURL, fit: fit, initialShowSettings: true))
        case "popup":
            root = AnyView(
                PopupView(monitor: monitor, regions: HitRegions(), onOpen: openURL)
                    .frame(width: PopupController.width + PopupController.margin * 2, height: 560)
                    .background(Color(hex: 0x1b2028))
            )
        default:
            root = AnyView(MainView(monitor: monitor, updates: updates, openURL: openURL, fit: fit))
        }

        let width = kind == "popup" ? PopupController.width + PopupController.margin * 2 : MainView.width
        embed(root.frame(width: width).ignoresSafeArea().preferredColorScheme(.dark), in: window)
        if kind == "popup" {
            window.setContentSize(NSSize(width: width, height: 560))
        }
        window.center()
        window.orderFront(nil)
        snapshotWindow = window

        // The demo takes about twenty seconds to reach "one passed, one
        // failed, one running", which is the picture worth taking.
        let delay = kind == "window" || kind == "popup" ? 19.5 : 2.5

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = window.contentView else {
                NSApp.terminate(nil)
                return
            }
            view.layoutSubtreeIfNeeded()

            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }

            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[kingprogress] \(message)\n".utf8))
    }
}

/// A window that can never take the keyboard, so rendering a snapshot does
/// not swallow whatever someone is typing in another app.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
