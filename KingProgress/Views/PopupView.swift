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

/// Which cards the stack shows. The window lists the same runs as the
/// stack, so while it is open the stack keeps to the cards from other apps,
/// which the window does not have.
@MainActor
@Observable
final class StackScope {
    var includesRuns = true
}

/// One card in the stack: a run, or a card from another app.
private enum StackItem: Identifiable {
    case run(TrackedRun)
    case card(ExternalCard)

    var id: String {
        switch self {
        case .run(let action): "run:\(action.key)"
        case .card(let card): "card:\(card.key)"
        }
    }

    /// When it joined the stack: a run when it started, a card when it was
    /// first shown.
    var arrival: Date {
        switch self {
        case .run(let action): action.startedAt
        case .card(let card): card.arrivedAt
        }
    }
}

/// The stack of cards in the top-right corner of the screen. Nothing outside
/// the cards themselves is painted: the panel is transparent.
struct PopupView: View {
    let monitor: RunMonitor
    let cards: ExternalCards
    let scope: StackScope
    let regions: HitRegions
    let onOpen: (URL) -> Void
    /// Dragging any card moves the whole stack.
    var onDrag: (StackDragPhase) -> Void = { _ in }
    /// For snapshots: the card drawn as if the cursor were on it.
    var hoverPreview: String? = nil

    @State private var clock = Clock()

    private let slide = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)

    private var theme: CardTheme { monitor.settings.cardTheme }

    /// Runs and cards from other apps in one column, newest first, in the
    /// order they arrived - not grouped by where they came from.
    private var items: [StackItem] {
        let runs = scope.includesRuns ? monitor.actions.map(StackItem.run) : []
        return (runs + cards.items.map(StackItem.card)).sorted { a, b in
            a.arrival == b.arrival ? a.id < b.id : a.arrival > b.arrival
        }
    }

    var body: some View {
        let items = items

        VStack(spacing: 0) {
            // Sits above the stack; only appears once there is something to
            // do with the stack as a whole: more than one card to clear, or
            // a stack that was dragged away and can go back home.
            if items.count > 1 || (isMoved && !items.isEmpty) {
                HStack(spacing: 6) {
                    Spacer()
                    if isMoved {
                        Button {
                            monitor.settings.setPopupOffset(.zero)
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .bold))
                                .frame(height: 13)
                        }
                        .buttonStyle(StackPillStyle(glass: theme == .glass))
                        .help("Back to the top right")
                        .hitRegion("go-home")
                        .transition(.opacity)
                    }
                    if items.count > 1 {
                        Button("Clear all \(items.count)") {
                            clearAll()
                        }
                        .buttonStyle(StackPillStyle(glass: theme == .glass))
                        .hitRegion("clear-all")
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            VStack(spacing: 0) {
                ForEach(items) { item in
                    card(item)
                        .hitRegion(item.id)
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
        .animation(slide, value: items.map(\.id))
        .animation(slide, value: isMoved)
        .onPreferenceChange(HitRegionKey.self) { rects in
            Task { @MainActor in regions.rects = rects }
        }
        .onChange(of: items.isEmpty, initial: true) { _, empty in
            clock.setRunning(!empty)
        }
        .onDisappear { clock.setRunning(false) }
    }

    @ViewBuilder
    private func card(_ item: StackItem) -> some View {
        switch item {
        case .run(let action):
            ActionCard(
                action: action,
                now: clock.now,
                isMine: isMine(action),
                theme: theme,
                showCommit: monitor.settings.showCommitMessage,
                onDismiss: { monitor.dismiss(action.key) },
                onOpen: { onOpen(action.url) },
                onCancel: { Task { await monitor.cancel(action.key) } },
                onDrag: onDrag
            )

        case .card(let card):
            ExternalCardView(
                card: card,
                now: clock.now,
                theme: theme,
                showsHover: card.key == hoverPreview,
                onOpen: { cards.open(card.key) },
                onAction: { cards.perform($0, on: card.key) },
                onDismiss: { cards.dismiss(card.key) },
                onHover: { cards.setHovering(card.key, $0) },
                onDrag: onDrag
            )
        }
    }

    /// Clears what the stack shows. Runs the stack is not showing - the
    /// window has them - are not the stack's to clear.
    private func clearAll() {
        if scope.includesRuns {
            monitor.dismissAll()
        }
        cards.dismissAll()
    }

    /// The stack has been dragged away from its home in the top-right corner.
    private var isMoved: Bool { monitor.settings.popupOffset != .zero }

    private func isMine(_ action: TrackedRun) -> Bool {
        guard let actor = action.actor, let me = monitor.myLogin else { return false }
        return actor.caseInsensitiveCompare(me) == .orderedSame
    }
}

private struct StackPillStyle: ButtonStyle {
    let glass: Bool
    @State private var hovering = false
    @Environment(\.drawnGlass) private var drawnGlass

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(ink)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)

        return Group {
            if #available(macOS 26, *), glass, !drawnGlass {
                // The same glass as the cards, as a small system-style pill.
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label
                    .background(Capsule().fill(Color(hex: 0x161b22, opacity: 0.9)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.1)))
                    .shadow(color: .black.opacity(0.7), radius: 9, y: 6)
            }
        }
        .opacity(hovering ? 1 : 0.75)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var ink: Color {
        if glass {
            return hovering ? .primary : .secondary
        }
        return hovering ? Theme.bright : Theme.muted2
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
