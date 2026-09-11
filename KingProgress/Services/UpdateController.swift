import Foundation
import Observation
import Sparkle

enum UpdateStatus: Equatable {
    case idle // nothing to do; the last check found no newer version
    case checking
    case downloading
    case ready // downloaded and staged; it installs on quit
    case error
}

/// What the settings screen and the menu bar menu show about updates.
@MainActor
@Observable
final class UpdateModel {
    var status: UpdateStatus = .idle
    let currentVersion = Bundle.main.shortVersion
    /// The version being downloaded, or waiting to be installed.
    var newVersion: String?
    /// What went wrong, for the error state.
    var message: String?
    /// When the last check finished.
    var checkedAt: Date?
}

/// Sparkle, set up the same way as in Kingtime: the appcast is checked every
/// six hours, a newer build is downloaded in the background and installed on
/// quit. On top of that the delegate keeps `model` up to date so the app can
/// show "Restart to update to …" itself, and install straight away when asked.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    let model = UpdateModel()

    private var controller: SPUStandardUpdaterController!
    private var installNow: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater {
        controller.updater
    }

    var canCheck: Bool {
        updater.canCheckForUpdates
    }

    /// A user-initiated check, with Sparkle's own progress and result dialogs.
    func checkNow() {
        guard canCheck, model.status != .ready else {
            return
        }
        model.status = .checking
        model.message = nil
        updater.checkForUpdates()
    }

    /// Quit, swap in the downloaded version and come back up.
    @discardableResult
    func installUpdate() -> Bool {
        guard let installNow else {
            return false
        }
        installNow()
        return true
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            // A version that is already staged is announced again on every
            // check. Re-running the download UI for it would only flicker.
            if model.status == .ready, model.newVersion == item.displayVersionString {
                return
            }
            model.newVersion = item.displayVersionString
            model.checkedAt = Date()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            if model.status != .ready {
                model.status = .idle
                model.newVersion = nil
                model.message = nil
                model.checkedAt = Date()
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        Task { @MainActor in
            model.status = .downloading
            model.newVersion = item.displayVersionString
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Task { @MainActor in
            model.status = .error
            model.message = error.localizedDescription
            model.checkedAt = Date()
        }
    }

    /// Sparkle has the new version unpacked and will install it on quit.
    /// Returning true keeps Sparkle's own "ready to install" prompt away; the
    /// menu bar menu and the settings screen offer the restart instead.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            installNow = immediateInstallHandler
            model.status = .ready
            model.newVersion = item.displayVersionString
            model.message = nil
            model.checkedAt = Date()
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            // A failed check is not worth nagging about - it retries in a few
            // hours. But do not throw away an update that already downloaded.
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {
                return
            }
            if model.status != .ready {
                model.status = .error
                model.message = error.localizedDescription
                model.checkedAt = Date()
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor in
            if model.status == .checking {
                model.status = error == nil ? .idle : .error
                model.message = error?.localizedDescription
                model.checkedAt = Date()
            }
        }
    }
}
