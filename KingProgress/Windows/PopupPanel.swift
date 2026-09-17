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
    /// How much of the top of the column has to stay on screen: about a card.
    private static let keepVisible: CGFloat = 150
    /// Dropped this close to home, the stack goes home.
    private static let snap: CGFloat = 14

    private let panel = PopupPanel()
    private let regions = HitRegions()
    private let settings: AppSettings
    private(set) var isShowing = false
    private var interactive = false
    /// Where the cursor and the panel were when the current drag began.
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var hideWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    init(monitor: RunMonitor, openURL: @escaping (URL) -> Void) {
        settings = monitor.settings
        let root = PopupView(monitor: monitor, regions: regions, onOpen: openURL, onDrag: { [weak self] in self?.handleDrag($0) })
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        applyAppearance()
        followOffset()

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

    /// The stack was put back home from the settings (or moved by anything
    /// else that is not a drag): go where it says.
    private func followOffset() {
        withObservationTracking {
            _ = settings.popupOffset
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isShowing, self.drag == nil {
                    // Glide there, so it is clear where the cards went.
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.3
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.panel.animator().setFrame(self.bounds(), display: true)
                    }
                }
                self.followOffset()
            }
        }
    }

    // The primary display, like the Electron version: the one with the
    // menu bar.
    private var homeScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    private var size: CGSize {
        let area = homeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: Self.width + Self.margin * 2, height: max(240, area.height - Self.margin))
    }

    /// The panel's top-left corner when nobody has moved it: the top-right
    /// of the primary display.
    private var home: CGPoint {
        let area = homeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: (area.maxX - size.width).rounded(), y: area.maxY.rounded())
    }

    private func bounds() -> NSRect {
        let offset = settings.popupOffset
        return frame(topLeft: CGPoint(x: home.x + offset.width, y: home.y + offset.height))
    }

    /// The panel with its top-left corner as close to `topLeft` as the
    /// screen it is on allows. The panel never changes size, so dragged down
    /// it hangs off the bottom of the screen; it is transparent and
    /// click-through there, and the cards are at its top. What is kept on
    /// screen is the top of the column, with room for a card.
    private func frame(topLeft: CGPoint) -> NSRect {
        let size = size
        let probe = CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y - 1)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? nearestScreen(to: probe) ?? homeScreen
        var corner = topLeft

        if let area = screen?.visibleFrame {
            corner.x = min(max(corner.x, area.minX), area.maxX - size.width)
            corner.y = min(max(corner.y, area.minY + Self.keepVisible), area.maxY)
        }

        return NSRect(x: corner.x.rounded(), y: (corner.y - size.height).rounded(), width: size.width, height: size.height)
    }

    private func nearestScreen(to point: CGPoint) -> NSScreen? {
        NSScreen.screens.min { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }
    }

    private func distance(from point: CGPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: - Dragging
    //
    // Dragging any card moves the whole column. There is nothing to grab but
    // the cards: the panel around them is invisible and stays that way.

    private func handleDrag(_ phase: StackDragPhase) {
        switch phase {
        case .began(let mouse):
            let frame = panel.frame
            drag = (mouse, CGPoint(x: frame.minX, y: frame.maxY))

        case .moved:
            guard let drag else { return }
            let mouse = NSEvent.mouseLocation
            let target = CGPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y)
            panel.setFrame(frame(topLeft: target), display: false)

        case .ended:
            guard drag != nil else { return }
            drag = nil

            var offset = CGSize(width: panel.frame.minX - home.x, height: panel.frame.maxY - home.y)
            // Dropped about where it came from: that is home.
            if abs(offset.width) < Self.snap, abs(offset.height) < Self.snap {
                offset = .zero
            }
            settings.setPopupOffset(offset)
            panel.setFrame(bounds(), display: true)
        }
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
        drag = nil
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
        // Mid-drag the cursor can be a frame ahead of the card under it.
        // Going click-through then would drop the drag.
        if drag != nil {
            // Unless the card went away mid-drag and took the end of the
            // gesture with it: then the button is up and nobody told us.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                handleDrag(.ended)
            }
            return
        }

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
