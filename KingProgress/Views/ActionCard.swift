import SwiftUI

/// One workflow run. The same card is used in the floating stack and in
/// the window.
struct ActionCard: View {
    let action: TrackedRun
    let now: Date
    let isMine: Bool
    let onDismiss: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private var state: ActionState { action.state }
    private var isRunning: Bool { state.isActive }
    private var isDone: Bool { !isRunning }
    private var accent: Color { state.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head

            workflowLine
                .padding(.top, 5)

            if let detailLine {
                Text(detailLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.detail)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 6)
                    .help(detailLine)
            }

            track
                .padding(.top, 10)

            meta
                .padding(.top, 7)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 11, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x202731, opacity: 0.97), Color(hex: 0x131820, opacity: 0.97)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            // The 1px inset highlight along the top edge.
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? accent.mixed(with: Color.white.opacity(0.09), fraction: 0.6) : Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.75 : 0.7), radius: hovering ? 14 : 12, y: hovering ? 12 : 10)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
        .scaleEffect(pressed ? 0.994 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        // The whole card opens the run on GitHub. One gesture does both the
        // press effect and the click: a separate tap gesture would lose to
        // the press gesture underneath it and never fire. Dragging away
        // before letting go cancels, like a button.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { value in
                    pressed = false
                    if abs(value.translation.width) < 8, abs(value.translation.height) < 8 {
                        onOpen()
                    }
                }
        )
        .help("Open this run on GitHub")
    }

    // MARK: - Pieces

    private var head: some View {
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
            (Text(repoOwner.isEmpty ? "" : "\(repoOwner)/").foregroundColor(Theme.muted).fontWeight(.medium)
                + Text(repoName).foregroundColor(Theme.bright).fontWeight(.semibold))
                .font(.system(size: 13))
                .tracking(-0.13)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(action.repo)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.muted2)
                .opacity(hovering ? 0.75 : 0)
                .padding(.leading, -2)

            pill

            DismissButton(action: onDismiss)
                .padding(.trailing, -3)
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            if isRunning {
                PulseDot()
            }
            Text(state.label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .foregroundStyle(accent.mixed(with: .white, fraction: 0.18))
        .background(Capsule().fill(state.accentSoft))
        .overlay(Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 1))
        .fixedSize()
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
                    .foregroundStyle(Theme.branch)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted2)
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))

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
            Text(elapsedLabel)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.elapsed)

            if let byLine {
                Text(byLine)
                    .foregroundStyle(Theme.dim)
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
        .foregroundStyle(Theme.muted)
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
        isRunning && expected == nil && action.jobsTotal == 0
    }

    private var detailLine: String? {
        if isDone {
            return nil
        }
        guard let job = action.currentJob else {
            return state == .queued ? "Waiting for a runner" : nil
        }
        if let step = action.currentStep {
            return "\(job) → \(step)"
        }
        return job
    }

    private var elapsedLabel: String {
        isDone ? "Took \(formatDuration(elapsed))" : formatClock(elapsed)
    }

    private var rightLabel: String {
        if isDone {
            return action.jobsTotal > 0 ? "\(action.jobsTotal) jobs" : ""
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Path { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addLine(to: CGPoint(x: 10, y: 10))
                path.move(to: CGPoint(x: 10, y: 2))
                path.addLine(to: CGPoint(x: 2, y: 10))
            }
            .stroke(hovering ? Theme.bright : Theme.muted2, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 12, height: 12)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .opacity(hovering ? 1 : 0.55)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
