import Foundation

/// Everything the helper knows about the machine at one instant.
struct SensorSnapshot {
    var displays: Presence
    var displayCount: Int
    var lidClosed: Bool
    var onAC: Bool
    var battery: Int?
    var thermalDanger: Bool
    var consoleUID: uid_t?
}

/// A grant reduced to the only things the decision depends on.
struct GrantView {
    var uid: uid_t
    var sinceRenewed: TimeInterval
    var sinceStarted: TimeInterval
    var external: Int
    var batteryFloor: Int
}

/// The arm predicate, as a pure function.
///
/// This is the whole safety argument of the tool, so it is deliberately kept
/// free of IOKit, clocks and state: it can be exercised exhaustively without
/// root and without touching the machine. Every condition fails closed — the
/// only path to `true` is one where every single check passed.
enum Policy {

    static func decide(grant: GrantView?,
                       sensors: SensorSnapshot,
                       displayBadFor: TimeInterval?,
                       displayGrace: TimeInterval) -> (arm: Bool, reason: String) {
        guard let grant else { return (false, "not requested") }

        // Deadman. Covers crash, kill -9, logout, and a wedged app alike.
        if grant.sinceRenewed > Wire.heartbeatTimeout {
            return (false, "app stopped responding")
        }
        if grant.sinceStarted > Wire.sessionCap {
            return (false, "8 hour session limit reached")
        }
        // nil console user is the login window; a different uid is fast user
        // switching. Neither may hold the flag.
        guard let console = sensors.consoleUID, console == grant.uid else {
            return (false, "no matching console user")
        }
        if grant.external < 1 {
            return (false, "no external display")
        }
        // The helper's own check must agree with the app, but one bad reading
        // during a lid-close transition is not proof the monitor is gone.
        if sensors.displays != .present {
            if let badFor = displayBadFor, badFor > displayGrace {
                return (false, sensors.displays == .absent
                        ? "no external display"
                        : "cannot verify external display")
            }
        }
        if sensors.thermalDanger {
            return (false, "thermal warning")
        }
        if grant.batteryFloor > 0, !sensors.onAC,
           let battery = sensors.battery, battery < grant.batteryFloor {
            return (false, "battery below \(grant.batteryFloor)%")
        }
        return (true, "")
    }
}
