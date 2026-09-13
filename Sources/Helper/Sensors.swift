import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SystemConfiguration

/// Three-valued answer. `unknown` always resolves to "disarm" in the predicate:
/// an unreadable sensor must never look like a safe one.
enum Presence {
    case present, absent, unknown
}

/// Every sensor here is pure IOKit or SystemConfiguration, deliberately.
///
/// CoreGraphics display enumeration is NOT usable from a system-domain daemon:
/// every CG* display symbol resolves into SkyLight (a WindowServer RPC), and
/// its failure mode without a window server is `kCGErrorSuccess` with count 0 —
/// indistinguishable from "no displays attached", which is the exact direction
/// that would leave a Mac awake in a bag. The app does CoreGraphics; we don't.
enum Sensors {

    // IOKit message constants. The IOPM.h macros do not import into Swift
    // ("structure not supported"), so they are expanded here:
    //   iokit_family_msg(sub_iokit_powermanagement, x)
    //     = sys_iokit(0xE0000000) | err_sub(13)(0x34000) | x
    // Values cross-checked by compiling the real macros with cc.
    static let msgClamshellStateChange: UInt32 = 0xE003_4100
    static let msgDarkWakeThermalEmergency: UInt32 = 0xE003_4160
    // Likewise iokit_common_msg(x) = sys_iokit | x, from IOMessage.h.
    static let msgCanSystemSleep: UInt32 = 0xE000_0270
    static let msgSystemWillSleep: UInt32 = 0xE000_0280
    static let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

    static func rootDomain() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = rootDomain()
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    /// Authoritative view of the flag we manage — what the kernel actually
    /// believes, not what pmset's exit code claimed.
    static func sleepDisabled() -> Bool? { rootDomainBool("SleepDisabled") }

    static func lidClosed() -> Bool { rootDomainBool("AppleClamshellState") ?? false }

    /// Independent second opinion on "is a monitor really attached?".
    ///
    /// `IOMobileFramebufferShim` is a private, Apple-Silicon-specific class, so
    /// this is a heuristic and is treated as one. Nub shapes observed on this
    /// machine: the built-in panel has NO `external` key at all (absent, not
    /// false), an empty DP port has `external = true` but no `DisplayAttributes`,
    /// and a live external monitor has both.
    static func externalDisplays() -> (Presence, Int) {
        var iterator: io_iterator_t = 0
        let match = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator)
        guard match == KERN_SUCCESS, iterator != 0 else { return (.unknown, -1) }
        defer { IOObjectRelease(iterator) }

        var nubs = 0
        var attached = 0
        while case let nub = IOIteratorNext(iterator), nub != 0 {
            defer { IOObjectRelease(nub) }
            nubs += 1
            let isExternal = IORegistryEntryCreateCFProperty(
                nub, "external" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false        // absent means built-in
            let attributes = IORegistryEntryCreateCFProperty(
                nub, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            let hasProduct = attributes?["ProductAttributes"] != nil
            if isExternal && hasProduct { attached += 1 }
        }
        // No nubs at all means the class name stopped matching (an OS change):
        // report unknown so the predicate disarms, rather than reporting zero.
        guard nubs > 0 else { return (.unknown, -1) }
        return (attached > 0 ? .present : .absent, attached)
    }

    static func onAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let type = IOPSGetProvidingPowerSourceType(blob).takeRetainedValue() as String
        return type == (kIOPSACPowerValue as String)
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

    /// Bonus disarm trigger only — never a safety mechanism.
    ///
    /// This machine publishes no thermal warning level at all
    /// (`IOPMGetThermalWarningLevel` returns kIOReturnNotFound), so this reads
    /// "fine" forever. The heartbeat and the display check are the real safety.
    static func thermalDanger() -> Bool {
        var level: UInt32 = 0
        guard IOPMGetThermalWarningLevel(&level) == kIOReturnSuccess else { return false }
        // The level enum is not monotonic — Normal 0, Danger 5, Critical 10,
        // Warning 100, Trap 110, Unknown 255 — so a `>=` comparison would read
        // Critical as safe. Anything that is neither Normal nor Unknown is bad.
        return level != UInt32(kIOPMThermalLevelNormal) && level != UInt32(kIOPMThermalLevelUnknown)
    }

    /// nil at the login window / fast-user-switch limbo, which must never arm.
    static func consoleUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil else { return nil }
        return uid
    }
}
