import AppKit
import SwiftUI

// What every card in the stack is made of, whoever it is from: `ActionCard`
// for runs, `ExternalCardView` for the cards other apps send. Kept in one
// place so the two kinds read as one stack rather than two lookalikes.

/// The inks a card's text is drawn in. Classic keeps the GitHub-dark
/// palette. Glass uses the system's own label colours, so the text follows
/// the Mac's light or dark look and stays readable over whatever the glass
/// is on top of.
struct CardInk {
    let glass: Bool

    var bright: Color { glass ? .primary : Theme.bright }
    var text: Color { glass ? Color.primary.opacity(0.85) : Theme.cardText }
    var muted: Color { glass ? .secondary : Theme.muted }
    var soft: Color { glass ? .secondary : Theme.muted2 }
}

extension EnvironmentValues {
    /// Snapshots cannot capture the system's glass or its backdrop blur, so
    /// they ask for a drawn stand-in: a tinted, see-through pane.
    @Entry var drawnGlass = false
}

/// Dresses the content as a card. Glass is the system's own Liquid Glass
/// where the Mac has it (macOS 26 and up), so the cards look like the rest
/// of the system they are floating over: the OS draws the material, the rim
/// light and the shadow. Older systems get a frosted stand-in built on the
/// same backdrop blur the HUD panels use.
struct CardChrome: ViewModifier {
    static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    let theme: CardTheme
    let hovering: Bool
    /// What the edge leans towards under the cursor: the card's accent.
    let tint: Color

    @Environment(\.drawnGlass) private var drawnGlass

    private var isGlass: Bool { theme == .glass }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *), isGlass, !drawnGlass {
            content
                .clipShape(Self.shape)
                .glassEffect(.regular.interactive(), in: Self.shape)
        } else {
            content
                .background(surface)
                .overlay(alignment: .top) {
                    // The 1px inset highlight along the top edge; a glass pane
                    // catches more light there.
                    Rectangle().fill(Color.white.opacity(isGlass ? 0.3 : 0.06)).frame(height: 1)
                }
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(edge, lineWidth: 1))
                .shadow(color: .black.opacity(shadowStrength), radius: hovering ? 14 : 12, y: hovering ? 12 : 10)
                .shadow(color: .black.opacity(isGlass ? 0.25 : 0.5), radius: 3, y: 2)
        }
    }

    /// What the card is made of, when the system does not draw it for us:
    /// a solid dark gradient, or a frosted pane with a faint sheen.
    @ViewBuilder
    private var surface: some View {
        switch theme {
        case .classic:
            LinearGradient(
                colors: [Color(hex: 0x202731, opacity: 0.97), Color(hex: 0x131820, opacity: 0.97)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .glass where drawnGlass:
            Color(hex: 0x262a32, opacity: 0.52)
        case .glass:
            ZStack {
                FrostedBackdrop()
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var edge: Color {
        let rest = Color.white.opacity(isGlass ? 0.24 : 0.09)
        return hovering ? tint.mixed(with: rest, fraction: 0.6) : rest
    }

    // A glass pane floats lighter than a solid slab.
    private var shadowStrength: Double {
        if isGlass {
            return hovering ? 0.45 : 0.38
        }
        return hovering ? 0.75 : 0.7
    }
}

/// The glowing strip down a card's left edge, the at-a-glance colour. More
/// than one colour splits it into equal segments from top to bottom, each
/// with its own glow: a card about mail in three accounts wears all three.
struct AccentEdge: View {
    let colors: [Color]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in
                Rectangle()
                    .fill(colors[index])
                    .shadow(color: colors[index], radius: 6)
            }
        }
        .frame(width: 3)
        .opacity(0.9)
    }
}

/// Countdown to a card leaving on its own: drains from the full width to
/// nothing along the bottom edge, so it is obvious the card is about to go.
struct LingerBar: View {
    let color: Color
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(color)
                .opacity(0.5)
                .frame(width: proxy.size.width * fraction, height: 2)
                .animation(.linear(duration: 0.6), value: fraction)
        }
        .frame(height: 2)
    }
}

/// Pressing, clicking and dragging a card. One gesture does both the press
/// effect and the click: a separate tap gesture would lose to the press
/// gesture underneath it and never fire. Dragging away before letting go
/// cancels, like a button. In the floating stack, dragging away moves the
/// stack instead.
struct CardPress: ViewModifier {
    /// Set in the floating stack, where dragging a card moves the stack. In
    /// the window a card stays where it is.
    let onDrag: ((StackDragPhase) -> Void)?
    /// The press turned into a drag of the stack.
    var onDragBegan: () -> Void = {}
    let onClick: () -> Void

    /// How far a press may wander and still be a click.
    private static let dragSlop: CGFloat = 5

    @State private var pressed = false
    /// Where on screen the current press started.
    @State private var pressOrigin: CGPoint?
    @State private var dragging = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.994 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in trackPress() }
                    .onEnded { value in
                        let wasDragging = dragging
                        pressed = false
                        pressOrigin = nil
                        dragging = false
                        if wasDragging {
                            onDrag?(.ended)
                            return
                        }
                        guard abs(value.translation.width) < 8, abs(value.translation.height) < 8 else { return }
                        onClick()
                    }
            )
    }

    private func trackPress() {
        let mouse = NSEvent.mouseLocation

        guard let pressOrigin else {
            pressOrigin = mouse
            pressed = true
            return
        }
        guard let onDrag else {
            return
        }

        if !dragging {
            guard hypot(mouse.x - pressOrigin.x, mouse.y - pressOrigin.y) > Self.dragSlop else { return }
            dragging = true
            pressed = false
            onDragBegan()
            onDrag(.began(pressOrigin))
        }
        onDrag(.moved)
    }
}

/// The × in the top-right corner of a card.
struct DismissButton: View {
    let glass: Bool
    let action: () -> Void
    @State private var hovering = false

    private var ink: Color {
        if glass {
            return hovering ? .primary : .secondary
        }
        return hovering ? Theme.bright : Theme.muted2
    }

    var body: some View {
        Button(action: action) {
            Path { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addLine(to: CGPoint(x: 10, y: 10))
                path.move(to: CGPoint(x: 10, y: 2))
                path.addLine(to: CGPoint(x: 2, y: 10))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 12, height: 12)
            .frame(width: 18, height: 18)
            .background(Circle().fill((glass ? Color.primary : Color.white).opacity(hovering ? 0.1 : 0)))
            .opacity(hovering ? 1 : 0.55)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The small filled pill in a card's one-line strip: "Cancel run" when a
/// run asks whether it should stop, the undo on a strip card.
struct InlineButtonStyle: ButtonStyle {
    let tint: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.vertical, 2.5)
            .padding(.horizontal, 9)
            .foregroundStyle(Color.white)
            .background(Capsule().fill(tint.opacity(hovering ? 1 : 0.85)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
