import AppKit
import SwiftUI

/// The transparent, click-through column pinned to the top-right of the
/// screen that the cards live in. Nothing but the cards is ever painted, so
/// the panel always fits the content exactly and the cards are free to
/// animate in and out beyond their own bounds.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Only becomes key if something in it needs the keyboard, which
        // nothing does - so a click on a card never takes focus away.
        becomesKeyOnlyIfNeeded = true
        // The cards float above ordinary windows, but no higher than that.
        //
        // The obvious level for an overlay is the screen saver level, and
        // that is exactly the problem: it also sits above the system's own
        // notification banners, which land in the same top-right corner. A
        // WhatsApp message would arrive behind our cards and go unread.
        // Floating keeps the cards over whatever the user is working in
        // while letting the system speak over us.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click, like any HUD should: the panel
/// is never the key window, and a click on a card must still count.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PopupController {
    static let width: CGFloat = 384
    static let margin: CGFloat = 16

    private let panel = PopupPanel()
    private let regions = HitRegions()
    private let settings: AppSettings
    private(set) var isShowing = false
    private var interactive = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var hideWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    init(monitor: RunMonitor, openURL: @escaping (URL) -> Void) {
        settings = monitor.settings
        let root = PopupView(monitor: monitor, regions: regions, onOpen: openURL)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        applyAppearance()

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isShowing else { return }
                self.panel.setFrame(self.bounds(), display: true)
            }
        }
    }

    /// Classic cards are GitHub-dark whatever the Mac looks like. Glass
    /// cards are meant to look like the system they float over, so they
    /// follow its light or dark appearance - and switch along with it.
    private func applyAppearance() {
        withObservationTracking {
            panel.appearance = settings.cardTheme == .glass ? nil : NSAppearance(named: .darkAqua)
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyAppearance() }
        }
    }

    private func bounds() -> NSRect {
        // The primary display, like the Electron version: the one with the
        // menu bar.
        let screen = NSScreen.screens.first ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Self.width + Self.margin * 2
        let height = max(240, area.height - Self.margin)

        return NSRect(x: (area.maxX - width).rounded(), y: (area.maxY - height).rounded(), width: width, height: height)
    }

    /// For `KINGPROGRESS_DEBUG`: where the panel is and what it would catch.
    var debugDescription: String {
        "popup visible: \(panel.isVisible) frame: \(panel.frame) interactive: \(interactive) level: \(panel.level.rawValue) regions: \(regions.rects.mapValues { NSStringFromRect($0) })"
    }

    func show() {
        hideWork?.cancel()
        hideWork = nil

        if isShowing, panel.isVisible {
            return
        }

        panel.setFrame(bounds(), display: true)
        panel.orderFrontRegardless() // never steal focus from whatever the user is doing
        isShowing = true
        startMouseMonitors()
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        setInteractive(false)
        stopMouseMonitors()
        isShowing = false
        panel.orderOut(nil)
    }

    /// Hide once the last card has finished sliding out, instead of blinking
    /// the whole stack away.
    func hideWhenSettled() {
        guard isShowing else {
            return
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Click-through
    //
    // The panel ignores the mouse by default so it never gets in the way. It
    // only becomes interactive while the cursor is actually over a card.

    private func startMouseMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                Task { @MainActor in self?.updateInteractivity() }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                Task { @MainActor in self?.updateInteractivity() }
                return event
            }
        }
    }

    private func stopMouseMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func updateInteractivity() {
        guard isShowing else {
            setInteractive(false)
            return
        }

        let mouse = NSEvent.mouseLocation

        guard panel.frame.contains(mouse), let content = panel.contentView else {
            setInteractive(false)
            return
        }

        // Screen -> window (bottom-left origin) -> SwiftUI (top-left origin).
        let inWindow = panel.convertPoint(fromScreen: mouse)
        let point = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
        let overCard = regions.rects.values.contains { $0.contains(point) }

        setInteractive(overCard)
    }

    private func setInteractive(_ on: Bool) {
        if on == interactive {
            return
        }

        interactive = on
        panel.ignoresMouseEvents = !on

        if on {
            startWatchdog()
        } else {
            stopWatchdog()
        }
    }

    // Safety net: if the cursor leaves the panel without us noticing, the
    // panel would stay clickable and swallow clicks meant for the app
    // underneath. Poll the real cursor position while interactive.
    private func startWatchdog() {
        if watchdog != nil {
            return
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateInteractivity() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}
