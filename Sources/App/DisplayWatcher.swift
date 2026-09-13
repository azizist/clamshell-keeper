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
    private var debounce: DispatchWorkItem?
    private var zeroConfirmation: DispatchWorkItem?

    /// How long a "no external displays" reading must hold before it is
    /// believed. A genuine unplug is delayed by this much; a lid-close
    /// transition artefact is filtered out entirely.
    private static let zeroConfirmationDelay: TimeInterval = 2.5

    func start(onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        externalCount = Self.currentExternalCount()

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // The "about to change" pass reports a list that has not settled.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DisplayWatcher.shared.scheduleRecount()
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

    private func recount() {
        let count = Self.currentExternalCount()
        zeroConfirmation?.cancel()
        zeroConfirmation = nil
        guard count != externalCount else { return }

        if count == 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, Self.currentExternalCount() == 0 else { return }
                self.externalCount = 0
                self.onChange?(0)
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
