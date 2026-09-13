import Foundation
import IOKit.ps

/// Battery figures for the menu's status line. Purely cosmetic — the helper
/// reads its own copy of all of this and never trusts what the app reports.
enum PowerInfo {
    static func onAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return (IOPSGetProvidingPowerSourceType(blob).takeRetainedValue() as String)
            == (kIOPSACPowerValue as String)
    }

    static func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = description[kIOPSMaxCapacityKey as String] as? Int,
                  max > 0
            else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }
}
