import Foundation

/// Everything the app can see about the displays at one instant.
struct DisplaySnapshot {
    /// The built-in is in CGGetActiveDisplayList. Membership, not
    /// CGDisplayIsActive — that returns -1 (truthy) for an ID that no longer
    /// exists, so it inverts on exactly the failure it would exist to catch.
    var builtinActive: Bool
    /// Active displays that CoreGraphics says are not built-in. This alone is
    /// a weak gate — Sidecar, AirPlay and DisplayLink all pass it.
    var externalActive: Int
    /// The helper's independent IOKit count of physically attached external
    /// panels. Cross-checking the two is what keeps a Sidecar iPad from being
    /// accepted as "the display you will still be able to see".
    var physicalExternalConfirmed: Bool
    var lidClosed: Bool
    /// False when the private symbol did not resolve — an OS update removed it.
    var mechanismAvailable: Bool
    /// Consecutive failed disable attempts. Never latches the enable path.
    var disableFailures: Int
}

enum DisplayAction: Equatable {
    case none
    case enable
    case disable
}

/// The built-in-display predicate, as a pure function.
///
/// Same argument as Policy.decide in the helper: no CoreGraphics, no clocks, no
/// state, so every branch can be exercised without touching the machine.
///
/// The asymmetry is the whole design. Turning the panel back ON is the safe
/// direction — unconditional, never gated, never given up on. Turning it OFF is
/// the direction that can leave someone unable to see anything, so it has to
/// pass every check. A wrong `.enable` costs a flicker; a wrong `.disable`
/// costs the screen.
enum DisplayPolicy {

    static let maxDisableFailures = 3

    static func decide(externalOnly intent: Bool, _ display: DisplaySnapshot) -> (DisplayAction, String) {
        // THE RULE, ahead of everything else: lid open and no external display
        // means the built-in must be on. No setting, no intent, no failure
        // count and no sensor doubt may override it, because in that state it
        // is the only screen there is.
        if !display.lidClosed, display.externalActive < 1, !display.builtinActive {
            return (.enable, "no external display")
        }

        // With the lid shut the built-in is legitimately gone — the clamshell
        // feature's territory, not ours. Do nothing in either direction rather
        // than repeatedly trying to light a panel inside a closed lid.
        if display.lidClosed {
            return (.none, "lid closed")
        }

        if !display.builtinActive {
            // Every reason to put it back, checked before any reason to keep it
            // off. Note there is no failure latch here on purpose.
            if !intent { return (.enable, "turned off") }
            if !display.physicalExternalConfirmed { return (.enable, "external display unconfirmed") }
            if !display.mechanismAvailable { return (.enable, "display control unavailable") }
            return (.none, "")
        }

        guard intent else { return (.none, "") }
        guard display.mechanismAvailable else {
            return (.none, "not supported on this macOS version")
        }
        guard display.externalActive >= 1 else {
            return (.none, "needs an external display")
        }
        guard display.physicalExternalConfirmed else {
            return (.none, "waiting to confirm the external display")
        }
        guard display.disableFailures < maxDisableFailures else {
            return (.none, "could not turn the built-in display off")
        }
        return (.disable, "")
    }
}
