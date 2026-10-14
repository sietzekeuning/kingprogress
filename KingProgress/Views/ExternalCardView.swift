import AppKit
import SwiftUI

/// A card another app put in the stack. Same chrome, inks and gestures as a
/// run's card, so the stack reads as one; what is on it is whatever the
/// client sent, in one of a few shapes:
/// - an avatar, a title, a subtitle, a body and a caption, with buttons that
///   appear under the cursor - a new mail;
/// - the same with a small glyph before the title instead of an avatar;
/// - a head row over a few short rows - "3 new messages";
/// - a single line with a check and an undo - "Archived".
struct ExternalCardView: View {
    static let maxRows = 4
    static let maxActions = 3

    let card: ExternalCard
    let now: Date
    let theme: CardTheme
    /// For snapshots: drawn as if the cursor were on it, so its buttons show.
    var showsHover = false
    let onOpen: () -> Void
    let onAction: (String) -> Void
    let onDismiss: () -> Void
    /// The cursor came onto the card or left it; its countdown waits meanwhile.
    let onHover: (Bool) -> Void
    /// Set in the floating stack, where dragging a card moves the stack.
    var onDrag: ((StackDragPhase) -> Void)? = nil

    @State private var hovering = false

    private var isGlass: Bool { theme == .glass }
    private var ink: CardInk { CardInk(glass: isGlass) }
    private var isHovered: Bool { hovering || showsHover }
    private var accents: [Color] { card.accent.map { Color(hex: $0) } }
    private var accent: Color { accents.first ?? Theme.muted }

    // The initials disc is a step lighter than the card in Classic. On
    // glass it is a tint of whatever the text is, so it keeps its contrast
    // in the light appearance as well as the dark one.
    private var initialsFill: Color { isGlass ? Color.primary.opacity(0.16) : Color(hex: 0x33333a) }
    private var initialsInk: Color { isGlass ? .primary : Color(hex: 0xd4d4da) }

    var body: some View {
        content
            .padding(EdgeInsets(top: 12, leading: 16, bottom: card.strip == nil ? 11 : 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                AccentEdge(colors: accents)
            }
            .overlay(alignment: .bottom) {
                if let fraction = card.lingerFraction(at: now) {
                    // An edge split between colours has no one colour to
                    // drain in, so that bar is neutral.
                    LingerBar(color: accents.count == 1 ? accent : ink.soft, fraction: fraction)
                }
            }
            .modifier(CardChrome(theme: theme, hovering: isHovered, tint: accent))
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .contentShape(CardChrome.shape)
            .onHover { over in
                hovering = over
                onHover(over)
            }
            // The card itself opens whatever it is about, in the app that sent it.
            .modifier(CardPress(onDrag: onDrag, onClick: onOpen))
            .help(card.help ?? "")
    }

    @ViewBuilder
    private var content: some View {
        if let strip = card.strip {
            stripRow(strip)
        } else {
            HStack(alignment: .top, spacing: 11) {
                if let avatar = card.avatar {
                    AvatarView(avatar: avatar, small: false, initialsFill: initialsFill, initialsInk: initialsInk)
                        .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    headRow

                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ink.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.top, 1)
                    }

                    if let text = card.body {
                        Text(text)
                            .font(.system(size: 11.5))
                            .lineSpacing(2.3)
                            .foregroundStyle(ink.soft)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }

                    if !card.rows.isEmpty {
                        rows
                            .padding(.top, 8)
                    }

                    if card.caption != nil || !card.actions.isEmpty {
                        // A point more under a block of text, for the air its
                        // last line leaves under itself in the design.
                        bottomRow
                            .padding(.top, card.body == nil && card.rows.isEmpty ? 9 : 10)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var headRow: some View {
        HStack(spacing: 7) {
            // In the avatar's place on a card without one, like a run's
            // status dot.
            if card.avatar == nil, let glyph = card.glyph {
                LineIcon(icon: glyph)
                    .foregroundStyle(ink.soft)
                    .frame(width: 12, height: 12)
            }

            Text(card.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.13)
                .foregroundStyle(ink.bright)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(card.language.age(of: card.date, now: now))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(ink.muted)
                .fixedSize()

            DismissButton(glass: isGlass, action: onDismiss)
                .padding(.trailing, -3)
        }
        .frame(height: 20)
    }

    private var rows: some View {
        // Rows line up whether or not each one brought a picture.
        let pictured = card.rows.contains { $0.avatar != nil }

        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(card.rows.prefix(Self.maxRows).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    if let avatar = row.avatar {
                        AvatarView(avatar: avatar, small: true, initialsFill: initialsFill, initialsInk: initialsInk)
                    } else if pictured {
                        Color.clear.frame(width: 16, height: 16)
                    }

                    Text(row.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ink.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 92, alignment: .leading)

                    Text(row.subtitle ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ink.soft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 16)
            }
        }
    }

    // The buttons only show under the cursor: at rest the card is something
    // to read, not a toolbar, and the caption has the whole row.
    private var bottomRow: some View {
        HStack(spacing: 6) {
            if let dot = card.captionDot {
                Circle()
                    .fill(Color(hex: dot))
                    .frame(width: 6, height: 6)
            }

            Text(card.caption ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(ink.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered, !card.actions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(card.actions.prefix(Self.maxActions).enumerated()), id: \.offset) { _, action in
                        Button {
                            onAction(action.id)
                        } label: {
                            HStack(spacing: 5) {
                                if let icon = action.icon {
                                    LineIcon(icon: icon)
                                        .frame(width: 12, height: 12)
                                }
                                Text(action.title)
                            }
                        }
                        .buttonStyle(CardButtonStyle(glass: isGlass))
                        .fixedSize()
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(height: 22)
    }

    private func stripRow(_ strip: CardStrip) -> some View {
        HStack(spacing: 8) {
            LineIcon(icon: .check, lineWidth: 2.4)
                .foregroundStyle(ActionState.success.accent)
                .frame(width: 13, height: 13)
                .frame(width: 14, height: 14)

            Text(strip.text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ink.bright)
                .lineLimit(1)
                .layoutPriority(1)

            Text(strip.detail ?? "")
                .font(.system(size: 12))
                .foregroundStyle(ink.soft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let button = strip.button {
                Button(button.title) {
                    onAction(button.id)
                }
                .buttonStyle(InlineButtonStyle(tint: Theme.blueStrong))
                .fixedSize()
            }
        }
        .frame(height: 20)
    }
}

/// The picture at the start of a card or a row: a logo on a light tile, or
/// someone's initials.
private struct AvatarView: View {
    let avatar: CardAvatar
    /// A row's 16-point picture rather than a card's 30-point one.
    let small: Bool
    let initialsFill: Color
    let initialsInk: Color

    private var size: CGFloat { small ? 16 : 30 }

    var body: some View {
        switch avatar {
        case .image(let image):
            if small {
                // A row is too small for a tile: the logo is the tile.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                // Logos are drawn for white pages; on a dark card most of them
                // would vanish without one.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0xf4f4f6)))
            }

        case .initials(let initials):
            Text(initials)
                .font(.system(size: small ? 8 : 11, weight: .semibold))
                .foregroundStyle(initialsInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: size, height: size)
                .background {
                    if small {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(initialsFill)
                    } else {
                        Circle().fill(initialsFill)
                    }
                }
        }
    }
}

/// A button on a card: outlined, with a small icon, brighter under the cursor.
private struct CardButtonStyle: ButtonStyle {
    let glass: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var ink: Color {
        if glass {
            return .primary
        }
        return hovering ? Theme.bright : Theme.text
    }

    private var border: Color {
        if glass {
            return Color.primary.opacity(hovering ? 0.5 : 0.28)
        }
        return hovering ? Theme.muted2 : Theme.border2
    }
}

/// The line icons a card can ask for by name, drawn on a 24-point grid with
/// round 2-point strokes and scaled to whatever frame they are given.
struct LineIcon: View {
    let icon: CardIcon
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            context.stroke(
                path.applying(CGAffineTransform(scaleX: scale, y: scale)),
                with: .style(.foreground),
                style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private var path: Path {
        var path = Path()

        func line(_ points: (CGFloat, CGFloat)...) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
        }

        switch icon {
        case .archive:
            path.addRoundedRect(in: CGRect(x: 3.5, y: 4.5, width: 17, height: 4.5), cornerSize: CGSize(width: 1, height: 1))
            line((5, 9), (5, 18.5))
            path.addQuadCurve(to: CGPoint(x: 6.5, y: 20), control: CGPoint(x: 5, y: 20))
            path.addLine(to: CGPoint(x: 17.5, y: 20))
            path.addQuadCurve(to: CGPoint(x: 19, y: 18.5), control: CGPoint(x: 19, y: 20))
            path.addLine(to: CGPoint(x: 19, y: 9))
            line((10, 13), (14, 13))

        case .check:
            line((4, 12.5), (8.5, 17), (20, 6.5))

        case .reply:
            line((9.5, 7.5), (4.5, 12), (9.5, 16.5))
            line((4.5, 12), (14, 12))
            path.addRelativeArc(center: CGPoint(x: 14, y: 17.5), radius: 5.5, startAngle: .degrees(-90), delta: .degrees(90))
            path.addLine(to: CGPoint(x: 19.5, y: 18.5))

        case .open:
            line((7, 17), (17, 7))
            line((8.5, 7), (17, 7), (17, 15.5))

        case .trash:
            line((4, 7), (20, 7))
            line((9.5, 7), (9.5, 5.5))
            path.addQuadCurve(to: CGPoint(x: 11, y: 4), control: CGPoint(x: 9.5, y: 4))
            path.addLine(to: CGPoint(x: 13, y: 4))
            path.addQuadCurve(to: CGPoint(x: 14.5, y: 5.5), control: CGPoint(x: 14.5, y: 4))
            path.addLine(to: CGPoint(x: 14.5, y: 7))
            line((6, 7), (6.9, 18.6))
            path.addQuadCurve(to: CGPoint(x: 8.4, y: 20), control: CGPoint(x: 7, y: 20))
            path.addLine(to: CGPoint(x: 15.6, y: 20))
            path.addQuadCurve(to: CGPoint(x: 17.1, y: 18.6), control: CGPoint(x: 17, y: 20))
            path.addLine(to: CGPoint(x: 18, y: 7))
            line((10, 11), (10, 16))
            line((14, 11), (14, 16))

        case .envelope:
            path.addRoundedRect(in: CGRect(x: 3, y: 5.5, width: 18, height: 13), cornerSize: CGSize(width: 2, height: 2))
            line((3.5, 7), (12, 13), (20.5, 7))

        case .bell:
            line((6, 16.5), (6, 11))
            path.addRelativeArc(center: CGPoint(x: 12, y: 11), radius: 6, startAngle: .degrees(180), delta: .degrees(180))
            path.addLine(to: CGPoint(x: 18, y: 16.5))
            path.addLine(to: CGPoint(x: 19.5, y: 18))
            path.addLine(to: CGPoint(x: 4.5, y: 18))
            path.closeSubpath()
            path.move(to: CGPoint(x: 10, y: 20.5))
            path.addRelativeArc(center: CGPoint(x: 12, y: 20.5), radius: 2, startAngle: .degrees(180), delta: .degrees(-180))
        }

        return path
    }
}
