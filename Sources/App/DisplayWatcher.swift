import AppKit
import CoreGraphics

/// Answers "is an external display attached?" from the user session, where
/// CoreGraphics is actually trustworthy.
///
/// Two observers, not one: the CG reconfiguration callback is the authoritative
/// edge, and the AppKit notification is the point at which NSScreen's cached
/// snapshot has caught up. Both are edge-triggered and both can coalesce or
/// double-fire, so state is always re-read, never accumulated.
final class DisplayWatcher {

    static let shared = DisplayWatcher()
    private init() {}

    /// Confirmed count. Everything else in the app reads this, so there is one
    /// source of truth and a heartbeat can never report an unconfirmed zero.
    private(set) var externalCount = 0
    private var onChange: ((Int) -> Void)?
    /// Fires after every settled recount, including ones where the external
    /// count did not move. The power path only cares about changes; the
    /// built-in-display path also needs the lid-open transition, which changes
    /// nothing about the external count but is exactly when the panel comes
    /// back and may need turning off again.
    private var onSettled: (() -> Void)?
    /// Fires ~250ms after any reconfiguration that leaves no external display.
    /// Deliberately much faster than `zeroConfirmationDelay`: waiting 2.5s is
    /// right when the cost of being wrong is "the Mac stayed awake", and wrong
    /// when it is "the screen is black".
    private var onExternalLoss: (() -> Void)?
    private var debounce: DispatchWorkItem?
    private var zeroConfirmation: DispatchWorkItem?

    /// How long a "no external displays" reading must hold before it is
    /// believed. A genuine unplug is delayed by this much; a lid-close
    /// transition artefact is filtered out entirely.
    private static let zeroConfirmationDelay: TimeInterval = 2.5

    func start(onChange: @escaping (Int) -> Void,
               onSettled: @escaping () -> Void = {},
               onExternalLoss: @escaping () -> Void = {}) {
        self.onChange = onChange
        self.onSettled = onSettled
        self.onExternalLoss = onExternalLoss
        externalCount = Self.currentExternalCount()

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // The "about to change" pass reports a list that has not settled.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DisplayWatcher.shared.scheduleRecount()
            DisplayWatcher.shared.scheduleLossCheck()
        }, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                DisplayWatcher.shared.scheduleRecount()
            }
    }

    /// A clamshell transition emits a remove/remove/add burst; settle first.
    private func scheduleRecount() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recount() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The safe direction, and the only one allowed to skip the debounce: it
    /// never turns anything off, it only asks the controller to reconsider.
    /// Never called synchronously from the reconfiguration callback — the
    /// CoreGraphics header is explicit that callbacks must not reconfigure.
    private func scheduleLossCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, Self.currentExternalCount() == 0 else { return }
            self.onExternalLoss?()
        }
    }

    private func recount() {
        let count = Self.currentExternalCount()
        zeroConfirmation?.cancel()
        zeroConfirmation = nil
        // Fires even when the count is unchanged — disabling the built-in does
        // not move it, so this is the only signal the display path would get.
        defer { onSettled?() }
        guard count != externalCount else { return }

        if count == 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, Self.currentExternalCount() == 0 else { return }
                self.externalCount = 0
                self.onChange?(0)
                self.onSettled?()
            }
            zeroConfirmation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.zeroConfirmationDelay,
                                          execute: work)
            return
        }

        externalCount = count
        onChange?(count)
    }

    /// CoreGraphics is the source of truth here, not NSScreen. Display IDs are
    /// never cached: a clamshell transition renumbers them (the external
    /// display observed on this machine moved from 0x2 to 0x4 on lid close).
    static func currentExternalCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}
