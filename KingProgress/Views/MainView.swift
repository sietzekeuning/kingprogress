import SwiftUI

/// The window behind the menu bar icon: the header bar, then either the
/// running cards or the settings.
struct MainView: View {
    static let width: CGFloat = 440
    private static let barHeight: CGFloat = 38
    private static let minHeight: CGFloat = 150
    private static let maxHeight: CGFloat = 820

    let monitor: RunMonitor
    let updates: UpdateController
    let openURL: (URL) -> Void
    /// Asks the window to take this content height.
    let fit: (CGFloat) -> Void
    var initialShowSettings = false

    @State private var showSettings = false
    @State private var clock = Clock()

    private let slide = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: Self.barHeight)

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            ScrollView {
                stack
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .reportHeight()
            }
        }
        .background(Theme.bg)
        // Measure the real content instead of guessing per-card heights, so
        // the window hugs whatever is in it.
        .onPreferenceChange(ContentHeightKey.self) { content in
            let height = max(Self.minHeight, min(Self.barHeight + 1 + content + 8, Self.maxHeight))
            Task { @MainActor in fit(height) }
        }
        .onAppear { showSettings = initialShowSettings }
        .onChange(of: monitor.actions.isEmpty, initial: true) { _, empty in
            clock.setRunning(!empty)
        }
        .onDisappear { clock.setRunning(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                BrandIcon(size: 18)
                    .foregroundStyle(Theme.blue)
                Text("KingProgress")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.12)
                    .foregroundStyle(Theme.cardText)
            }

            Spacer()

            Text(countLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

            if !monitor.actions.isEmpty, !showSettings {
                HeaderIconButton(systemName: "trash", size: 11, help: "Clear all") {
                    monitor.dismissAll()
                }
            }

            HeaderIconButton(systemName: "gearshape.fill", size: 12, isOn: showSettings, help: "Settings") {
                showSettings.toggle()
            }
        }
        .padding(.leading, 78) // room for the traffic lights
        .padding(.trailing, 10)
    }

    @ViewBuilder
    private var stack: some View {
        if showSettings {
            SettingsView(monitor: monitor, updates: updates)
        } else if monitor.actions.isEmpty {
            VStack(spacing: 4) {
                Text("Nothing running")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.emptyTitle)
                Text("Workflow runs show up here the moment they start")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(monitor.actions) { action in
                    ActionCard(
                        action: action,
                        now: clock.now,
                        isMine: isMine(action),
                        onDismiss: { monitor.dismiss(action.key) },
                        onOpen: { openURL(action.url) }
                    )
                    .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    .transition(.cardSlide(distance: 24, scale: 0.97, blur: 0))
                }
            }
            .animation(slide, value: monitor.actions.map(\.key))
        }
    }

    private var countLabel: String {
        if showSettings {
            return "settings"
        }
        if monitor.actions.isEmpty {
            return "idle"
        }
        let running = monitor.actions.filter { $0.state.isActive }.count
        return running > 0 ? "\(running) running" : "\(monitor.actions.count) finished"
    }

    private func isMine(_ action: TrackedRun) -> Bool {
        guard let actor = action.actor, let me = monitor.myLogin else { return false }
        return actor.caseInsensitiveCompare(me) == .orderedSame
    }
}
