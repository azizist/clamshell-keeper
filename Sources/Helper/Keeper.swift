import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// The state machine. Two states only: SAFE (SleepDisabled forced off) and
/// ARMED (SleepDisabled on). SAFE is the default, the startup state, and the
/// resolution of every unknown.
///
/// The menu bar app is a sensor and a UI, never an authority. It can *request*
/// an arm; it cannot hold one. If it dies, is killed, logs out, or stops seeing
/// an external display, the grant goes stale and the Mac sleeps normally again.
final class Keeper {

    static let shared = Keeper()
    private init() {}

    private struct Grant {
        let uid: uid_t
        let startedAt: UInt64
        var renewedAt: UInt64
        var external: Int
        var batteryFloor: Int
    }

    private var grant: Grant?
    private var armed = false
    private var lastReason = "not requested"
    /// When the helper's own display check first went bad. A lid-close tears
    /// the display list down and rebuilds it, so one bad reading is not proof
    /// the monitor is gone — but five seconds of them is.
    private var displayCheckBadSince: UInt64?
    private static let displayGrace: TimeInterval = 5

    private var systemPowerPort: IONotificationPortRef?
    private var systemPowerNotifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var interestPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = 0
    private var tick: DispatchSourceTimer?

    /// Monotonic nanoseconds. CLOCK_MONOTONIC on Darwin keeps counting across
    /// system sleep, and unlike a wall clock it cannot be moved by an NTP jump
    /// or a user changing the date to extend a grant.
    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    private static func seconds(since t: UInt64) -> TimeInterval {
        Double(now() &- t) / 1_000_000_000
    }

    // MARK: - Lifecycle

    func start() {
        // Unconditional first act, before anything else runs: whatever the
        // previous session, a crash, a panic, or powerd re-pushing the
        // persisted pref left behind, we start SAFE.
        Log.info("starting — forcing SAFE")
        Mechanism.apply(false)

        registerClamshellAndThermal()
        registerSystemPower()
        registerPowerSource()
        registerThermalNotify()
        startTick()
    }

    /// Clears the flag synchronously. Called from the SIGTERM/SIGINT handler,
    /// so that `launchctl bootout` can never leave a Mac that cannot sleep.
    func shutdown() {
        Log.info("shutting down — forcing SAFE")
        grant = nil
        Mechanism.apply(false)
    }

    // MARK: - Requests from the app

    func requestArm(external: Int, batteryFloor: Int, uid: uid_t) -> Wire.Status {
        if var existing = grant, existing.uid == uid {
            existing.renewedAt = Self.now()
            existing.external = external
            existing.batteryFloor = batteryFloor
            grant = existing
        } else {
            let now = Self.now()
            grant = Grant(uid: uid, startedAt: now, renewedAt: now,
                          external: external, batteryFloor: batteryFloor)
            Log.info("arm requested by uid \(uid) (external=\(external), floor=\(batteryFloor))")
        }
        return evaluate()
    }

    func requestDisarm() -> Wire.Status {
        if grant != nil { Log.info("disarm requested") }
        grant = nil
        return evaluate()
    }

    func status() -> Wire.Status { evaluate() }

    // MARK: - The predicate (see Policy.swift — it is a pure function)

    /// Re-evaluated on every request, every event, and every tick. Any false
    /// condition drops straight back to SAFE.
    @discardableResult
    private func evaluate() -> Wire.Status {
        let (displayPresence, displayCount) = Sensors.externalDisplays()
        let sensors = SensorSnapshot(
            displays: displayPresence,
            displayCount: displayCount,
            lidClosed: Sensors.lidClosed(),
            onAC: Sensors.onAC(),
            battery: Sensors.batteryPercent(),
            thermalDanger: Sensors.thermalDanger(),
            consoleUID: Sensors.consoleUID())

        if displayPresence == .present {
            displayCheckBadSince = nil
        } else if displayCheckBadSince == nil {
            displayCheckBadSince = Self.now()
        }

        let view = grant.map {
            GrantView(uid: $0.uid,
                      sinceRenewed: Self.seconds(since: $0.renewedAt),
                      sinceStarted: Self.seconds(since: $0.startedAt),
                      external: $0.external,
                      batteryFloor: $0.batteryFloor)
        }
        let (shouldArm, reason) = Policy.decide(
            grant: view,
            sensors: sensors,
            displayBadFor: displayCheckBadSince.map { Self.seconds(since: $0) },
            displayGrace: Self.displayGrace)

        if shouldArm != armed {
            Log.info(shouldArm
                ? "ARMED (external=\(displayCount), lidClosed=\(sensors.lidClosed), onAC=\(sensors.onAC))"
                : "SAFE — \(reason)")
            armed = shouldArm
            Mechanism.apply(shouldArm)
            if !shouldArm { grant = nil }
        } else if Sensors.sleepDisabled() != shouldArm {
            // Reconciliation, both directions. Either the kernel says sleep is
            // disabled while nothing holds a grant (boot residue from the
            // persisted preference, a crash leftover, someone else's pmset), or
            // it says sleep is enabled while we believe we are armed (someone
            // cleared it by hand). Either way the kernel and this state machine
            // must agree, and this state machine is the authority.
            Log.warn("SleepDisabled out of sync with state — re-applying \(shouldArm)")
            Mechanism.apply(shouldArm)
        }

        lastReason = reason
        return Wire.Status(
            armed: armed,
            sleepDisabled: Sensors.sleepDisabled() ?? false,
            reason: reason,
            lidClosed: sensors.lidClosed,
            externalDisplays: displayCount,
            onAC: sensors.onAC,
            batteryPercent: sensors.battery ?? -1,
            helperVersion: HelperVersion.string)
    }

    // MARK: - Event sources (all session-free: no WindowServer anywhere)

    private func startTick() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        tick = timer
    }

    /// Clamshell open/close and dark-wake thermal emergency arrive as general
    /// interest notifications on IOPMrootDomain.
    private func registerClamshellAndThermal() {
        let service = Sensors.rootDomain()
        guard service != IO_OBJECT_NULL else {
            Log.error("could not open IOPMrootDomain")
            return
        }
        defer { IOObjectRelease(service) }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        interestPort = port
        let callback: IOServiceInterestCallback = { _, _, messageType, _ in
            switch messageType {
            case Sensors.msgClamshellStateChange:
                Keeper.shared.evaluate()
            case Sensors.msgDarkWakeThermalEmergency:
                Log.warn("dark wake thermal emergency")
                _ = Keeper.shared.requestDisarm()
            default:
                break
            }
        }
        let result = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest, callback, nil, &interestNotifier)
        if result != KERN_SUCCESS { Log.error("clamshell notification failed: \(result)") }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }

    /// Sleep/wake. Every notification must be acknowledged — an unacked
    /// kIOMessageCanSystemSleep stalls system sleep for ~30 s, which is itself
    /// exactly the hazard this tool exists to avoid.
    private func registerSystemPower() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let callback: IOServiceInterestCallback = { _, _, messageType, argument in
            switch messageType {
            case Sensors.msgCanSystemSleep, Sensors.msgSystemWillSleep:
                IOAllowPowerChange(Keeper.shared.rootPort, Int(bitPattern: argument))
            case Sensors.msgSystemHasPoweredOn:
                Keeper.shared.evaluate()
            default:
                break
            }
        }
        rootPort = IORegisterForSystemPower(nil, &port, callback, &notifier)
        guard rootPort != 0, let port else {
            Log.error("IORegisterForSystemPower failed")
            return
        }
        systemPowerPort = port
        systemPowerNotifier = notifier
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }

    private func registerPowerSource() {
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Keeper.shared.evaluate()
        }, nil)?.takeRetainedValue() else {
            Log.error("IOPSNotificationCreateRunLoopSource failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// notify(3) is not importable from Swift; the Darwin notify center is the
    /// same mechanism with a Swift-visible API. This only lowers latency — the
    /// 10 s tick re-reads the thermal level regardless.
    private func registerThermalNotify() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in Keeper.shared.evaluate() },
            kIOPMThermalWarningNotificationKey as CFString, nil, .deliverImmediately)
    }
}

enum HelperVersion {
    static let string = "1.0"
}
