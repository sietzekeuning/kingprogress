import SwiftUI

/// What the main window shows: the sign-in screen until there is a token,
/// then the cards and settings.
struct RootView: View {
    let monitor: RunMonitor
    let updates: UpdateController
    let clipboard: ClipboardWatcher
    let openURL: (URL) -> Void
    let fit: (CGFloat) -> Void

    var body: some View {
        Group {
            if monitor.isSignedIn {
                MainView(monitor: monitor, updates: updates, openURL: openURL, fit: fit)
            } else {
                LoginView(monitor: monitor, clipboard: clipboard, openURL: openURL, fit: fit)
            }
        }
        .frame(width: MainView.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        // The header bar draws under the traffic lights, like the Electron
        // window did; the safe area would otherwise push it below them.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
