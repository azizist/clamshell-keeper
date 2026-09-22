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

// MARK: - DisplayPolicy: turning the built-in panel off is the dangerous
// direction, so every gate on it is tested, and so is the rule that the safe
// direction is never gated.

func displays(builtinActive: Bool = true,
              externalActive: Int = 1,
              physicalConfirmed: Bool = true,
              lidClosed: Bool = false,
              available: Bool = true,
              failures: Int = 0) -> DisplaySnapshot {
    DisplaySnapshot(builtinActive: builtinActive, externalActive: externalActive,
                    physicalExternalConfirmed: physicalConfirmed, lidClosed: lidClosed,
                    mechanismAvailable: available, disableFailures: failures)
}

func act(_ intent: Bool, _ d: DisplaySnapshot) -> DisplayAction {
    DisplayPolicy.decide(externalOnly: intent, d).0
}

// The one way to turn it off.
check(act(true, displays()) == .disable,
      "disable: asked for, monitor present and confirmed, lid open")

// Every gate on the dangerous direction.
check(act(false, displays()) == .none, "no-op: not asked for, built-in already on")
check(act(true, displays(externalActive: 0)) == .none, "refuse: no external display")
check(act(true, displays(physicalConfirmed: false)) == .none,
      "refuse: external unconfirmed by the helper (Sidecar/AirPlay)")
check(act(true, displays(available: false)) == .none, "refuse: private API missing")
check(act(true, displays(failures: DisplayPolicy.maxDisableFailures)) == .none,
      "refuse: too many consecutive failures")
check(act(true, displays(lidClosed: true)) == .none, "refuse: lid closed")

// The safe direction, which must never be gated by anything.
check(act(false, displays(builtinActive: false)) == .enable, "restore: user turned it off")
check(act(true, displays(builtinActive: false, externalActive: 0)) == .enable,
      "restore: external display disappeared")
check(act(true, displays(builtinActive: false, physicalConfirmed: false)) == .enable,
      "restore: external no longer confirmed")
check(act(true, displays(builtinActive: false, available: false)) == .enable,
      "restore: private API vanished under us")
check(act(false, displays(builtinActive: false, failures: 99)) == .enable,
      "restore: the disable-failure latch must never block a restore")
check(act(true, displays(builtinActive: false)) == .none,
      "stay off: still asked for, monitor still there")
check(act(true, displays(failures: 99)) == .none,
      "latch only ever applies while the built-in is still on")

// THE RULE: lid open with no external display means the built-in comes on,
// whatever else is true. Each of these would be blocked by some other check if
// the rule were not evaluated first.
check(act(true, displays(builtinActive: false, externalActive: 0)) == .enable,
      "rule: lid open, no external, setting still on -> enable")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         failures: 99)) == .enable,
      "rule: beats the failure latch")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         available: false)) == .enable,
      "rule: still tries even if the private API looks unavailable")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         physicalConfirmed: true)) == .enable,
      "rule: a stale 'external confirmed' cannot suppress it")
check(act(false, displays(builtinActive: false, externalActive: 0)) == .enable,
      "rule: same with the setting off")

// Lid closed is the clamshell feature's territory: do nothing either way.
check(act(true, displays(builtinActive: false, lidClosed: true)) == .none,
      "lid closed: no attempt to light a panel inside a shut lid")
check(act(false, displays(builtinActive: false, lidClosed: true)) == .none,
      "lid closed: no enable attempt either")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
