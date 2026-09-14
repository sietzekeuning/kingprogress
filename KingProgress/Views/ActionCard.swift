import SwiftUI

/// One workflow run. The same card is used in the floating stack and in
/// the window.
struct ActionCard: View {
    let action: TrackedRun
    let now: Date
    let isMine: Bool
    let theme: CardTheme
    /// Whether to show the commit subject line under the workflow.
    let showCommit: Bool
    let onDismiss: () -> Void
    let onOpen: () -> Void
    let onCancel: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    /// The stop button was clicked; the head row is asking "are you sure?".
    @State private var confirming = false
    @Environment(\.colorScheme) private var colorScheme

    private var state: ActionState { action.state }
    private var isRunning: Bool { state.isActive }
    /// Waiting for a runner: nothing has happened yet, so there is nothing
    /// to time or to estimate.
    private var isQueued: Bool { state == .queued }
    private var isDone: Bool { !isRunning }
    private var accent: Color { state.accent }
    private var isGlass: Bool { theme == .glass }

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    // Classic keeps the GitHub-dark palette. Glass uses the system's own
    // label colours, so the text follows the Mac's light or dark look and
    // stays readable over whatever the glass is on top of.
    private var brightInk: Color { isGlass ? .primary : Theme.bright }
    private var textInk: Color { isGlass ? Color.primary.opacity(0.85) : Theme.cardText }
    private var mutedInk: Color { isGlass ? .secondary : Theme.muted }
    private var softInk: Color { isGlass ? .secondary : Theme.muted2 }
    private var dimInk: Color { isGlass ? Color.secondary.opacity(0.75) : Theme.dim }
    private var branchInk: Color { isGlass ? .secondary : Theme.branch }
    private var elapsedInk: Color { isGlass ? .secondary : Theme.elapsed }
    private var detailInk: Color { isGlass ? .accentColor : Theme.detail }
    private var chipFill: Color { isGlass ? Color.primary.opacity(0.08) : Color.white.opacity(0.06) }
    private var trackFill: Color { isGlass ? Color.primary.opacity(0.1) : Color.white.opacity(0.08) }

    var body: some View {
        chrome(content)
            .scaleEffect(pressed ? 0.994 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .contentShape(Self.shape)
            .onHover { over in
                hovering = over
                if !over {
                    confirming = false
                }
            }
            // The whole card opens the run on GitHub. One gesture does both the
            // press effect and the click: a separate tap gesture would lose to
            // the press gesture underneath it and never fire. Dragging away
            // before letting go cancels, like a button. While the card is
            // asking about a cancel, a click just withdraws the question.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { value in
                        pressed = false
                        guard abs(value.translation.width) < 8, abs(value.translation.height) < 8 else { return }
                        if confirming {
                            confirming = false
                        } else {
                            onOpen()
                        }
                    }
            )
            .help("Open this run on GitHub")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            head

            workflowLine
                .padding(.top, 5)

            if showCommit, let commit = action.commitMessage {
                HStack(spacing: 5) {
                    CommitGlyph()
                        .frame(width: 12, height: 12)
                        .opacity(0.7)
                    Text(commit)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(commit)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(textInk)
                .padding(.top, 5)
            }

            if let detailLine {
                Text(detailLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(action.cancelError != nil ? Theme.red : detailInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 6)
                    .help(detailLine)
            }

            track
                .padding(.top, 10)

            if !isQueued || byLine != nil {
                meta
                    .padding(.top, 7)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 11, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            // Left edge accent, doubles as the at-a-glance status colour.
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .shadow(color: accent, radius: 6)
                .opacity(0.9)
        }
        .overlay(alignment: .bottom) {
            if isDone {
                // Countdown to the automatic dismissal of a finished card.
                GeometryReader { proxy in
                    Rectangle()
                        .fill(accent)
                        .opacity(0.5)
                        .frame(width: proxy.size.width * lingerFraction, height: 2)
                        .animation(.linear(duration: 0.6), value: lingerFraction)
                }
                .frame(height: 2)
            }
        }
    }

    // MARK: - Chrome

    /// Dresses the content as a card. Glass is the system's own Liquid
    /// Glass where the Mac has it (macOS 26 and up), so the cards look like
    /// the rest of the system they are floating over: the OS draws the
    /// material, the rim light and the shadow. Older systems get a frosted
    /// stand-in built on the same backdrop blur the HUD panels use.
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        if #available(macOS 26, *), isGlass {
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
        return hovering ? accent.mixed(with: rest, fraction: 0.6) : rest
    }

    // A glass pane floats lighter than a solid slab.
    private var shadowStrength: Double {
        if isGlass {
            return hovering ? 0.45 : 0.38
        }
        return hovering ? 0.75 : 0.7
    }

    // MARK: - Pieces

    // The head row doubles as the confirm strip: a system alert would
    // activate the app and pull focus from whatever the user is doing,
    // which is exactly what the floating cards must never do. There is no
    // "no" button: clicking anywhere else on the card, leaving it, or six
    // seconds of nothing all put the row back.
    private var head: some View {
        ZStack {
            if confirming {
                confirmStrip.transition(.opacity)
            } else {
                headRow.transition(.opacity)
            }
        }
        // Same height either way, so the card does not jiggle on the switch.
        .frame(height: 20)
        .animation(.easeOut(duration: 0.15), value: confirming)
        .task(id: confirming) {
            // Nobody answered: put the row back rather than leave a question
            // hanging on a card that may sit there for minutes.
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled {
                confirming = false
            }
        }
    }

    private var confirmStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.red)
                .frame(width: 12, height: 12)

            Text("Cancel this run on GitHub?")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(brightInk)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Cancel run") {
                confirming = false
                onCancel()
            }
            .buttonStyle(InlineButtonStyle(tint: Theme.red))
        }
    }

    private var headRow: some View {
        HStack(spacing: 7) {
            Group {
                if isRunning {
                    Spinner(accent: accent)
                } else {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .shadow(color: accent, radius: 4)
                }
            }
            .frame(width: 12, height: 12)

            // The repository is what you scan for first, so it leads the card.
            // Its owner is nearly always the same across runs, so it is there
            // but dimmed.
            (Text(repoOwner.isEmpty ? "" : "\(repoOwner)/").foregroundColor(mutedInk).fontWeight(.medium)
                + Text(repoName).foregroundColor(brightInk).fontWeight(.semibold))
                .font(.system(size: 13))
                .tracking(-0.13)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(action.repo)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(softInk)
                .opacity(hovering ? 0.75 : 0)
                .padding(.leading, -2)

            pill

            if isRunning, !action.cancelling {
                CancelButton(glass: isGlass) { confirming = true }
            }

            DismissButton(glass: isGlass, action: onDismiss)
                .padding(.trailing, -3)
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            if isRunning {
                PulseDot()
            }
            Text((action.cancelling && isRunning ? "Cancelling" : state.label).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .foregroundStyle(pillInk)
        .background(Capsule().fill(state.accentSoft))
        .overlay(Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }

    // Lightened on dark, deepened on light, so the label keeps its
    // contrast against the soft fill either way.
    private var pillInk: Color {
        if isGlass, colorScheme == .light {
            return accent.mixed(with: .black, fraction: 0.3)
        }
        return accent.mixed(with: .white, fraction: 0.18)
    }

    private var workflowLine: some View {
        HStack(spacing: 5) {
            WorkflowGlyph()
                .frame(width: 12, height: 12)
                .opacity(0.7)

            Text(action.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(action.name)

            if let branch = action.branch {
                Text(branch)
                    .font(Theme.mono)
                    .foregroundStyle(branchInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(chipFill))
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(softInk)
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(trackFill)

                if isIndeterminate {
                    // No history and no jobs yet: show motion instead of a lie.
                    SweepingFill(accent: accent, width: proxy.size.width * 0.35, travel: proxy.size.width)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [accent.mixed(with: .black, fraction: 0.3), accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * progress)
                        .shadow(color: accent, radius: 4)
                        .animation(.linear(duration: 0.6), value: progress)
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private var meta: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let elapsedLabel {
                Text(elapsedLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(elapsedInk)
            }

            if let byLine {
                Text(byLine)
                    .foregroundStyle(dimInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text(rightLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(mutedInk)
    }

    // MARK: - Derived values

    private var repoOwner: String {
        let parts = action.repo.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    private var repoName: String {
        String(action.repo.split(separator: "/").last ?? "")
    }

    private var elapsed: TimeInterval {
        if isDone, let duration = action.duration {
            return duration
        }
        return max(0, now.timeIntervalSince(action.startedAt))
    }

    private var expected: TimeInterval? {
        action.expectedDuration
    }

    // Prefer the time-based estimate (median of the last 3 successful runs)
    // and fall back to how many jobs are done when there is no history yet.
    private var progress: Double {
        if isDone {
            return 1
        }
        if isQueued {
            return 0
        }

        if let expected, expected > 0 {
            // Ease out near the end so the bar never claims to be finished early.
            let raw = elapsed / expected
            return raw >= 1 ? 0.97 : min(0.97, raw)
        }

        if action.jobsTotal > 0 {
            return min(1, Double(action.jobsCompleted) / Double(action.jobsTotal))
        }

        return 0
    }

    private var isIndeterminate: Bool {
        state == .running && expected == nil && action.jobsTotal == 0
    }

    private var detailLine: String? {
        if isDone {
            return nil
        }
        if let cancelError = action.cancelError {
            return cancelError
        }
        guard let job = action.currentJob else {
            return state == .queued ? "Waiting for a runner" : nil
        }
        if let step = action.currentStep {
            return "\(job) → \(step)"
        }
        return job
    }

    private var elapsedLabel: String? {
        if isQueued {
            return nil
        }
        return isDone ? "Took \(formatDuration(elapsed))" : formatClock(elapsed)
    }

    private var rightLabel: String {
        if isDone {
            return action.jobsTotal > 0 ? "\(action.jobsTotal) jobs" : ""
        }
        if isQueued {
            return "" // the detail line already says it is waiting for a runner
        }

        let jobs = action.jobsTotal > 0 ? "\(action.jobsCompleted)/\(action.jobsTotal) jobs" : ""

        if let expected, expected > 0 {
            let remaining = expected - elapsed
            let eta = remaining > 0 ? "~\(formatDuration(remaining)) left" : "longer than usual"
            return jobs.isEmpty ? eta : "\(eta) · \(jobs)"
        }

        return jobs
    }

    // Only worth the pixels when somebody else set it off.
    private var byLine: String? {
        guard let actor = action.actor, !isMine else { return nil }
        return "by \(actor)"
    }

    // Drains from 1 to 0 over the linger window, so it is obvious the card is
    // about to leave on its own.
    private var lingerFraction: Double {
        guard isDone, let completedAt = action.completedAt else {
            return 1
        }
        let remaining = completedAt.addingTimeInterval(RunMonitor.completedLinger).timeIntervalSince(now)
        return max(0, min(1, remaining / RunMonitor.completedLinger))
    }
}

// MARK: - Bits with their own animation

private struct Spinner: View {
    let accent: Color
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.16), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: 11, height: 11)
        .rotationEffect(.degrees(-90))
        .onAppear { spinning = true }
    }
}

private struct PulseDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.primary)
            .frame(width: 5, height: 5)
            .opacity(pulsing ? 0.35 : 1)
            .scaleEffect(pulsing ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

private struct SweepingFill: View {
    let accent: Color
    let width: CGFloat
    let travel: CGFloat
    @State private var sweeping = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [accent.mixed(with: .black, fraction: 0.3), accent], startPoint: .leading, endPoint: .trailing))
            .frame(width: width)
            .shadow(color: accent, radius: 4)
            .offset(x: sweeping ? travel : -width)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: sweeping)
            .onAppear { sweeping = true }
    }
}

private struct DismissButton: View {
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

/// The stop square next to the dismiss cross on a running card. Red only
/// on hover, so a row of running cards does not look like a row of alarms.
private struct CancelButton: View {
    let glass: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(hovering ? Theme.red : (glass ? Color.secondary : Theme.muted2))
                .frame(width: 8, height: 8)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.red.opacity(hovering ? 0.18 : 0)))
                .opacity(hovering ? 1 : 0.55)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Cancel this run")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The "Cancel run" pill in the confirm strip.
private struct InlineButtonStyle: ButtonStyle {
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

/// The "git-commit" octicon: a ring on a line.
private struct CommitGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 16
            let stroke = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round)
            let mid = 8 * scale

            var line = Path()
            line.move(to: CGPoint(x: 0.75 * scale, y: mid))
            line.addLine(to: CGPoint(x: 4.5 * scale, y: mid))
            line.move(to: CGPoint(x: 11.5 * scale, y: mid))
            line.addLine(to: CGPoint(x: 15.25 * scale, y: mid))
            context.stroke(line, with: .style(.foreground), style: stroke)

            let ring = Path(ellipseIn: CGRect(x: 4.75 * scale, y: 4.75 * scale, width: 6.5 * scale, height: 6.5 * scale))
            context.stroke(ring, with: .style(.foreground), style: stroke)
        }
    }
}

/// The "workflow" octicon: two boxes joined by an elbow.
private struct WorkflowGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 16
            let stroke = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)

            var boxes = Path()
            boxes.addRoundedRect(in: CGRect(x: 0.75, y: 0.75, width: 5.5, height: 5.5).applying(.init(scaleX: scale, y: scale)), cornerSize: CGSize(width: 1.2 * scale, height: 1.2 * scale))
            boxes.addRoundedRect(in: CGRect(x: 9.75, y: 9.75, width: 5.5, height: 5.5).applying(.init(scaleX: scale, y: scale)), cornerSize: CGSize(width: 1.2 * scale, height: 1.2 * scale))
            context.stroke(boxes, with: .style(.foreground), style: stroke)

            var elbow = Path()
            elbow.move(to: CGPoint(x: 3.5 * scale, y: 6.25 * scale))
            elbow.addLine(to: CGPoint(x: 3.5 * scale, y: 11 * scale))
            elbow.addQuadCurve(to: CGPoint(x: 5 * scale, y: 12.5 * scale), control: CGPoint(x: 3.5 * scale, y: 12.5 * scale))
            elbow.addLine(to: CGPoint(x: 9.75 * scale, y: 12.5 * scale))
            context.stroke(elbow, with: .style(.foreground), style: stroke)
        }
    }
}
