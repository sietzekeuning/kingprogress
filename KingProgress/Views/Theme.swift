import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }

    /// CSS `color-mix(in srgb, self (1 - fraction), other fraction)`.
    func mixed(with other: Color, fraction: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(nsColor: a.blended(withFraction: fraction, of: b) ?? a)
    }
}

/// The GitHub-dark palette the Electron version used, so nothing moves.
enum Theme {
    static let bg = Color(hex: 0x0d1117)
    static let text = Color(hex: 0xc9d1d9)
    static let bright = Color(hex: 0xf0f6fc)
    static let cardText = Color(hex: 0xe6edf3)
    static let muted = Color(hex: 0x7d8590)
    static let muted2 = Color(hex: 0x8b949e)
    static let dim = Color(hex: 0x6e7681)
    static let elapsed = Color(hex: 0x9aa4ae)
    static let branch = Color(hex: 0xa9b3bd)
    static let emptyTitle = Color(hex: 0xadb6c0)
    static let border = Color(hex: 0x21262d)
    static let border2 = Color(hex: 0x30363d)
    static let divider = Color(hex: 0x1c2129)
    static let panel = Color(hex: 0x161b22)
    static let raised = Color(hex: 0x2b3440)
    static let blue = Color(hex: 0x58a6ff)
    static let blueStrong = Color(hex: 0x2f81f7)
    static let detail = Color(hex: 0x7fb4ff)
    static let green = Color(hex: 0x238636)
    static let greenHover = Color(hex: 0x2ea043)
    static let red = Color(hex: 0xf85149)

    static let mono = Font.system(size: 10, design: .monospaced)
}

extension ActionState {
    /// The card's accent: left edge, dot, pill and progress bar.
    var accent: Color {
        switch self {
        case .queued: Color(hex: 0xd0a12c)
        case .running: Color(hex: 0x4b93ff)
        case .success: Color(hex: 0x35b45f)
        case .failure, .timedOut: Color(hex: 0xf2504a)
        case .cancelled, .skipped, .neutral: Color(hex: 0x7d8590)
        case .actionRequired: Color(hex: 0xe08b2c)
        }
    }

    var accentSoft: Color {
        accent.opacity(0.16)
    }
}

// MARK: - Small reusable pieces

/// A 24x24 icon button in the window's header bar.
struct HeaderIconButton: View {
    let systemName: String
    let size: CGFloat
    var isOn = false
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn || hovering ? Theme.border : .clear))
                .foregroundStyle(isOn ? Theme.blue : (hovering ? Theme.bright : Theme.muted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The outlined "Sign out" / "Reset" / "Check now" button.
struct GhostButtonStyle: ButtonStyle {
    var small = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 10.5 : 11))
            .padding(.vertical, small ? 4 : 5)
            .padding(.horizontal, small ? 8 : 10)
            .foregroundStyle(hovering ? Theme.bright : Theme.text)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering ? Theme.muted2 : Theme.border2))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

/// The dark, bordered text field used in settings and on the login screen.
struct FieldChrome: ViewModifier {
    var focused: Bool
    var armed = false
    /// The login screen's paste field is a touch bigger than the settings fields.
    var large = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: large ? 12 : 11.5))
            .foregroundStyle(Theme.text)
            .padding(.vertical, large ? 8 : 6)
            .padding(.horizontal, large ? 10 : 9)
            .background(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: large ? 8 : 7).strokeBorder(armed ? Theme.greenHover : (focused ? Theme.blue : Theme.border2)))
            .clipShape(RoundedRectangle(cornerRadius: large ? 8 : 7))
    }
}

/// Reports the height of the view it is attached to, for windows that hug
/// their content.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func reportHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
    }
}

/// Ticks twice a second while there is something to count, so elapsed
/// clocks and progress bars move - and stays quiet otherwise.
@MainActor
@Observable
final class Clock {
    var now = Date()
    private var timer: Timer?

    func setRunning(_ running: Bool) {
        if running, timer == nil {
            now = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
        } else if !running, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 {
        return "\(total)s"
    }
    let minutes = total / 60
    let rest = total % 60
    return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m"
}
