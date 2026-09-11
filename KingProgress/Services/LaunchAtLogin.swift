import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// A build run from Xcode or a `build/` folder would otherwise register
    /// itself as a login item and stay there long after the session is over.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
}
