import AppKit
import SwiftUI

/// The window behind the menu bar icon. Fixed width; the height follows the
/// content, which reports it through `WindowFitter`.
final class MainWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MainView.width, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "KingProgress"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = NSColor(Theme.bg)
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        standardWindowButton(.zoomButton)?.isEnabled = false
        setFrameAutosaveName("KingProgressMain")
    }
}

/// Puts a SwiftUI view in a window without letting SwiftUI size the window:
/// as the window's content view, an NSHostingView resizes the window to its
/// own idea of the ideal height (safe area included) on every layout. One
/// plain view in between, and the fitter is the only thing that sizes it.
@MainActor
func embed<Content: View>(_ root: Content, in window: NSWindow) {
    let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = []
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    window.contentView = container
}

/// Resizes a window to the height its content asked for, keeping the top
/// edge where it is so the window grows and shrinks downwards.
@MainActor
final class WindowFitter {
    weak var window: NSWindow?

    func fit(height: CGFloat) {
        guard let window else {
            return
        }

        let height = height.rounded()
        var frame = window.frame

        if abs(frame.height - height) < 0.5, abs(frame.width - MainView.width) < 0.5 {
            return
        }

        frame.origin.y += frame.height - height
        frame.size.height = height
        frame.size.width = MainView.width
        window.setFrame(frame, display: true, animate: false)

        if ProcessInfo.processInfo.environment["KINGPROGRESS_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[kingprogress] window fitted to \(height): \(window.frame)\n".utf8))
        }
    }
}
