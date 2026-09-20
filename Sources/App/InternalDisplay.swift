import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// The only file in the project that touches a private API.
///
/// There is no public way to turn a display off — macOS 27's own Displays
/// settings has no such verb, and closing the lid remains the only sanctioned
/// route. The mechanism everything else uses (BetterDisplay, Lunar's BlackOut,
/// displayplacer) is `CGSConfigureDisplayEnabled`, re-exported through public
/// CoreGraphics from SkyLight's `SLSConfigureDisplayEnabled`. It needs no root,
/// no entitlement, and no private framework linkage — only a WindowServer
/// connection, which this app has and the root helper deliberately does not.
///
/// Three facts below were established by probing this machine, not by reading
/// documentation, and each one shapes the code:
///
///  1. A disabled built-in disappears from `CGGetOnlineDisplayList` as well as
///     the active list. It cannot be rediscovered, so its ID must be captured
///     while it is still on. Getting this wrong strands the panel off.
///  2. `kCGConfigureForAppOnly` really does revert on SIGKILL — the panel came
///     back within a second of `kill -9`, twice. That is the crash-safety
///     story, and it is why there is no watchdog process here.
///  3. `kCGConfigurePermanently` is the one option that writes to disk. Never
///     pass it: a black panel must not be able to survive a reboot.
enum InternalDisplay {

    private typealias ConfigureEnabled =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// Resolved once. nil means an OS update took the symbol away, which makes
    /// the whole feature unavailable rather than partially working.
    private static let configureEnabled: ConfigureEnabled? = {
        let global = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        for name in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
            if let symbol = dlsym(global, name) {
                return unsafeBitCast(symbol, to: ConfigureEnabled.self)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { configureEnabled != nil }

    /// Last known ID of the built-in panel, remembered from when it was last
    /// visible. Fact 1 above: without this there is no way back.
    private static var lastKnownBuiltinID: CGDirectDisplayID?

    // MARK: - Reading

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Refreshes the remembered ID whenever the panel is visible, and falls
    /// back to the remembered one when it is not.
    static func builtinID() -> CGDirectDisplayID? {
        if let current = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            lastKnownBuiltinID = current
            return current
        }
        return lastKnownBuiltinID
    }

    static func builtinIsActive() -> Bool {
        guard let id = builtinID() else { return false }
        return activeDisplays().contains(id)
    }

    static func activeExternalCount() -> Int {
        activeDisplays().filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    /// Cosmetic copy of the helper's reading. The helper keeps its own,
    /// authoritative one for power decisions; this one only labels the menu,
    /// exactly as PowerInfo does for the battery.
    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool ?? false
    }

    // MARK: - Writing

    /// Turns the built-in panel off. Refuses unless another active display will
    /// survive the change — the WindowServer has no such guard of its own, so
    /// this is the last thing standing between a toggle and a dark laptop.
    @discardableResult
    static func disable() -> Bool {
        guard let id = builtinID(), activeExternalCount() >= 1 else { return false }
        return apply(id: id, enabled: false)
    }

    /// Turns the built-in panel back on. Unconditional by design, and retried:
    /// `CGCompleteDisplayConfiguration` can fail transiently (the header notes
    /// a full-screen app can block it), and failing to re-enable is the one
    /// outcome that leaves someone unable to see their machine.
    @discardableResult
    static func enable(attempts: Int = 1) -> Bool {
        guard let id = builtinID() else { return false }
        for attempt in 1...max(1, attempts) {
            if apply(id: id, enabled: true) { return true }
            NSLog("ClamshellKeeper: re-enabling the built-in display failed (attempt \(attempt))")
            usleep(250_000)
        }
        // Last resort, and public API: put every display back the way the
        // system remembers it.
        CGRestorePermanentDisplayConfiguration()
        usleep(500_000)
        return builtinIsActive()
    }

    private static func apply(id: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard configureEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // .forAppOnly, never .permanently: app-scoped changes revert when this
        // process dies (fact 2), and nothing is written to disk (fact 3).
        guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else { return false }

        // Verify by list membership. The state takes a moment to propagate and
        // CGDisplayIsActive reads a process-local cache, so neither the return
        // code nor that predicate can be trusted here.
        usleep(600_000)
        return activeDisplays().contains(id) == enabled
    }
}
