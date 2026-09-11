import SwiftUI

/// Where the cards are on screen, so the transparent panel can be made
/// clickable exactly there and click-through everywhere else.
@MainActor
final class HitRegions {
    var rects: [String: CGRect] = [:]
}

struct HitRegionKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func hitRegion(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HitRegionKey.self, value: [id: proxy.frame(in: .named("popup"))])
        })
    }
}

/// The stack of cards in the top-right corner of the screen. Nothing outside
/// the cards themselves is painted: the panel is transparent.
struct PopupView: View {
    let monitor: RunMonitor
    let regions: HitRegions
    let onOpen: (URL) -> Void

    @State private var clock = Clock()

    private let slide = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            // Sits above the stack; only appears once there is more than one card.
            if monitor.actions.count > 1 {
                HStack {
                    Spacer()
                    Button("Clear all \(monitor.actions.count)") {
                        monitor.dismissAll()
                    }
                    .buttonStyle(ClearAllStyle())
                    .hitRegion("clear-all")
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            VStack(spacing: 0) {
                ForEach(monitor.actions) { action in
                    ActionCard(
                        action: action,
                        now: clock.now,
                        isMine: isMine(action),
                        onDismiss: { monitor.dismiss(action.key) },
                        onOpen: { onOpen(action.url) }
                    )
                    .hitRegion(action.key)
                    // The padding doubles as the gap between cards and as
                    // breathing room for the card's shadow.
                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .transition(.cardSlide(distance: 34, scale: 0.96, blur: 2))
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "popup")
        .animation(slide, value: monitor.actions.map(\.key))
        .onPreferenceChange(HitRegionKey.self) { rects in
            Task { @MainActor in regions.rects = rects }
        }
        .onChange(of: monitor.actions.isEmpty, initial: true) { _, empty in
            clock.setRunning(!empty)
        }
        .onDisappear { clock.setRunning(false) }
    }

    private func isMine(_ action: TrackedRun) -> Bool {
        guard let actor = action.actor, let me = monitor.myLogin else { return false }
        return actor.caseInsensitiveCompare(me) == .orderedSame
    }
}

private struct ClearAllStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(hovering ? Theme.bright : Theme.muted2)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background(Capsule().fill(Color(hex: 0x161b22, opacity: 0.9)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.1)))
            .shadow(color: .black.opacity(0.7), radius: 9, y: 6)
            .opacity(hovering ? 1 : 0.75)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - The slide-in / slide-out transition

private struct CardSlideModifier: ViewModifier {
    let active: Bool
    let distance: CGFloat
    let scale: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: active ? distance : 0)
            .scaleEffect(active ? scale : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? blur : 0)
    }
}

extension AnyTransition {
    /// Slides in from the right, slightly small and soft; leaves the same way.
    static func cardSlide(distance: CGFloat, scale: CGFloat, blur: CGFloat) -> AnyTransition {
        .modifier(
            active: CardSlideModifier(active: true, distance: distance, scale: scale, blur: blur),
            identity: CardSlideModifier(active: false, distance: distance, scale: scale, blur: blur)
        )
    }
}
