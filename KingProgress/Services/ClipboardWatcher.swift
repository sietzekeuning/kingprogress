import AppKit

/// While the login screen is open we keep an eye on the clipboard: the moment
/// a GitHub token is copied, the app can use it without the user having to
/// find the paste field.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChangeCount = 0

    func start(onToken: @escaping (String) -> Void) {
        stop()

        // Start from whatever is on the clipboard right now, so only a token
        // copied *after* this screen opened counts. Otherwise signing out
        // would sign you straight back in with the token still sitting there
        // from signing in.
        lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let pasteboard = NSPasteboard.general

                if pasteboard.changeCount == self.lastChangeCount {
                    return
                }
                self.lastChangeCount = pasteboard.changeCount

                if let text = pasteboard.string(forType: .string), GitHubAuth.looksLikeToken(text) {
                    onToken(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
