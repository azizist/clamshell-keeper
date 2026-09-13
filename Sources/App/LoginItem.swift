import Foundation
import ServiceManagement

/// "Start at Login" via SMAppService.mainApp.
///
/// Note this registers the *app*, not the helper: a LaunchDaemon inside an app
/// bundle would have to be notarized, which needs a paid Developer ID. The
/// helper is installed the legacy way, in /Library/LaunchDaemons, which Apple's
/// own header still blesses because writing there is protected by filesystem
/// permissions.
enum LoginItem {
    private static let versionKey = "registeredBuildVersion"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    // A rebuilt binary invalidates the existing registration;
                    // Apple's guidance is to unregister before re-registering.
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(currentBuild, forKey: versionKey)
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClamshellKeeper: login item change failed: \(error.localizedDescription)")
        }
    }

    /// Called at launch: a new build under the same registration goes stale.
    static func refreshIfRebuilt() {
        guard SMAppService.mainApp.status == .enabled,
              UserDefaults.standard.string(forKey: versionKey) != currentBuild
        else { return }
        setEnabled(true)
    }

    private static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
