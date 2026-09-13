import Foundation

// Runs with ./test.sh — no root, no machine state, nothing installed.
// Covers the two things that would actually hurt if they were wrong: the
// protocol parser (the only untrusted input the root helper accepts) and the
// arm predicate (the entire safety argument).

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        print("FAIL \(label)")
        failures += 1
    }
}

// MARK: - Protocol: only three verbs, strictly shaped

check(Wire.Request.parse("DISARM") != nil, "DISARM accepted")
check(Wire.Request.parse("STATUS") != nil, "STATUS accepted")
if case .arm(let external, let floor)? = Wire.Request.parse("ARM 2 20") {
    check(external == 2 && floor == 20, "ARM 2 20 parsed")
} else {
    check(false, "ARM 2 20 parsed")
}

for bad in ["ARM", "ARM 1", "ARM 1 2 3", "ARM -1 0", "ARM 99 0", "ARM 1 99", "ARM x 0",
            "arm 1 0", "DISARM now", "", "   ", "ARM 1 0; rm -rf /",
            "PMSET -a disablesleep 1", "ARM 1 0\u{0}"] {
    check(Wire.Request.parse(bad) == nil, "rejected: \(bad.isEmpty ? "<empty>" : bad)")
}
for request in [Wire.Request.disarm, .status, .arm(external: 3, batteryFloor: 20)] {
    check(Wire.Request.parse(request.line) != nil, "round trip: \(request.line)")
    check(request.line.utf8.count <= Wire.maxLineBytes, "within line limit: \(request.line)")
}

// MARK: - Policy: every path to "armed" and every path away from it

let grace: TimeInterval = 5

func sensors(displays: Presence = .present,
             lidClosed: Bool = true,
             onAC: Bool = false,
             battery: Int? = 80,
             thermal: Bool = false,
             console: uid_t? = 501) -> SensorSnapshot {
    SensorSnapshot(displays: displays, displayCount: displays == .present ? 1 : 0,
                   lidClosed: lidClosed, onAC: onAC, battery: battery,
                   thermalDanger: thermal, consoleUID: console)
}

func grant(uid: uid_t = 501, renewed: TimeInterval = 1, started: TimeInterval = 60,
           external: Int = 1, floor: Int = 0) -> GrantView {
    GrantView(uid: uid, sinceRenewed: renewed, sinceStarted: started,
              external: external, batteryFloor: floor)
}

func decide(_ g: GrantView?, _ s: SensorSnapshot, badFor: TimeInterval? = nil) -> (Bool, String) {
    Policy.decide(grant: g, sensors: s, displayBadFor: badFor, displayGrace: grace)
}

// The one and only way to be armed.
check(decide(grant(), sensors()).0, "armed: fresh grant, monitor present, console user")

// Fail-closed paths.
check(!decide(nil, sensors()).0, "safe: no grant at all")
check(!decide(grant(renewed: Wire.heartbeatTimeout + 1), sensors()).0,
      "safe: heartbeat stale (app crashed, killed, or logged out)")
check(!decide(grant(started: Wire.sessionCap + 1), sensors()).0,
      "safe: session cap reached")
check(!decide(grant(), sensors(console: nil)).0,
      "safe: no console user (login window / FileVault prompt)")
check(!decide(grant(uid: 501), sensors(console: 502)).0,
      "safe: different console user (fast user switching)")
check(!decide(grant(external: 0), sensors()).0,
      "safe: app reports no external display")
check(!decide(grant(), sensors(displays: .absent), badFor: grace + 1).0,
      "safe: helper confirms no external display")
check(!decide(grant(), sensors(displays: .unknown), badFor: grace + 1).0,
      "safe: helper cannot verify the display (private API stopped matching)")
check(!decide(grant(), sensors(thermal: true)).0, "safe: thermal warning")
check(!decide(grant(floor: 20), sensors(onAC: false, battery: 19)).0,
      "safe: below the battery floor on battery")

// Grace window: a lid-close tears the display list down and rebuilds it, and
// that must not read as "monitor unplugged".
check(decide(grant(), sensors(displays: .absent), badFor: 1).0,
      "armed: brief bad display reading is tolerated inside the grace window")
check(!decide(grant(), sensors(displays: .absent), badFor: grace + 0.1).0,
      "safe: bad display reading past the grace window is believed")

// Battery floor is opt-in and must not fire when it is off or on AC.
check(decide(grant(floor: 0), sensors(battery: 3)).0, "armed: floor off, battery ignored")
check(decide(grant(floor: 20), sensors(onAC: true, battery: 5)).0,
      "armed: below floor but on AC")
check(decide(grant(floor: 20), sensors(battery: nil)).0,
      "armed: floor set but battery level unreadable")

// Lid state alone decides nothing — it is the monitor that matters.
check(decide(grant(), sensors(lidClosed: false)).0, "armed: lid open is fine")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
