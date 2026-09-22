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

    /// Same shape as CGGetOnlineDisplayList, but SkyLight's own list: it
    /// includes displays CoreGraphics hides, which is the only way to find a
    /// display we have disabled.
    private typealias GetDisplayList =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

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

    private static let getDisplayList: GetDisplayList? = {
        let global = UnsafeMutableRawPointer(bitPattern: -2)
        for name in ["CGSGetDisplayList", "SLSGetDisplayList"] {
            if let symbol = dlsym(global, name) {
                return unsafeBitCast(symbol, to: GetDisplayList.self)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { configureEnabled != nil }

    /// Last known ID of the built-in panel. Only a hint: IDs are renumbered
    /// across sleep and clamshell transitions, so a remembered one can be
    /// stale, and enabling a stale ID fails silently. Always prefer a live
    /// lookup — see `builtinID()`.
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
    /// Every display SkyLight knows about, including ones we have disabled and
    /// which therefore appear in neither the online nor the active list.
    private static func skyLightDisplays() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return [] }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Resolved live, in descending order of trust. The remembered ID is the
    /// last resort rather than the first answer: it is the thing that goes
    /// stale across a lid cycle, which is precisely when it gets used.
    static func builtinID() -> CGDirectDisplayID? {
        if let current = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            lastKnownBuiltinID = current
            return current
        }
        if let hidden = skyLightDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            lastKnownBuiltinID = hidden
            return hidden
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
        for attempt in 1...max(1, attempts) {
            // Re-resolved every time round: an earlier attempt can itself
            // change the numbering.
            if let id = builtinID(), apply(id: id, enabled: true) { return true }
            NSLog("ClamshellKeeper: re-enabling the built-in display failed (attempt \(attempt))")
            usleep(250_000)
        }

        // Blunt fallback: enable everything SkyLight lists. Enabling a display
        // that is already enabled is a no-op, so the only cost is a moment of
        // reconfiguration, and it needs no correct ID to work.
        //
        // Note what is deliberately NOT here: CGRestorePermanentDisplayConfiguration().
        // It restores the permanent configuration, and the enabled bit is not
        // part of it — com.apple.windowserver.displays.plist has no Enabled or
        // Active key at all — so it cannot bring a disabled panel back.
        NSLog("ClamshellKeeper: falling back to enabling every known display")
        for id in skyLightDisplays() { _ = apply(id: id, enabled: true) }
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
