import AppKit
import ServiceManagement

/// The menu bar UI and the policy that drives the helper.
///
/// "Armed" here is only ever a *request*. The helper decides, and it will
/// refuse or revoke whenever it cannot independently confirm that an external
/// display is attached and a console user is present.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private enum Key {
        static let keepAwake = "keepAwakeEnabled"
        static let batteryFloor = "batteryFloorPercent"
        static let skipDisplayConfirmation = "skipDisplayConfirmation"
    }
    private static let defaultBatteryFloor = 20

    private let client = DaemonClient()
    private var statusItem: NSStatusItem!
    private var heartbeat: Timer?
    private var lastStatus: Wire.Status?
    private var helperReachable = true

    /// Deliberately NOT persisted, unlike keepAwake. If keepAwake survives a
    /// restart the worst case is a Mac that stayed awake; if this survived one,
    /// a black built-in panel would come back on its own at login, while an
    /// external is still negotiating its link after a cold boot.
    private var externalOnly = false
    private var displayReason = ""
    private var disableFailures = 0
    private var reconcilingDisplay = false

    /// What the user asked for, remembered across restarts. Auto behaviour
    /// hangs off this: while it is on, the app arms whenever a monitor is
    /// attached and stands down the moment one is not.
    private var keepAwake: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepAwake) }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepAwake) }
    }

    /// 0 means the floor is off. Off by default, deliberately: turning it on
    /// trades "runs the battery flat" for "stops working at 20%".
    private var batteryFloor: Int {
        get { UserDefaults.standard.integer(forKey: Key.batteryFloor) }
        set { UserDefaults.standard.set(newValue, forKey: Key.batteryFloor) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LoginItem.refreshIfRebuilt()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(armed: false)

        // Put the built-in back before anything else, unconditionally. The
        // analogue of the helper's "first act on every load is disablesleep 0":
        // it makes "no black panel survives a restart" true by construction
        // rather than by trusting the OS to have reverted it.
        reconcileDisplay()

        DisplayWatcher.shared.start(
            onChange: { [weak self] _ in self?.push() },
            onSettled: { [weak self] in self?.reconcileDisplay() },
            onExternalLoss: { [weak self] in self?.reconcileDisplay() })

        // The disabled state does not survive sleep/wake, so re-assert rather
        // than waiting up to 20s for the heartbeat to notice.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reconcileDisplay()
            }

        // The heartbeat is the deadman switch: stop sending and the helper
        // restores normal sleep within a minute, whatever killed us.
        let timer = Timer(timeInterval: Wire.heartbeatInterval, repeats: true) {
            [weak self] _ in self?.push()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        push()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort, and blocking on purpose: an async completion targeted at
        // the main queue would never run at this point. The helper's 60 s
        // timeout covers us anyway if this does not land.
        client.sendBlocking(.disarm)
        // macOS reverts an app-scoped display configuration when the process
        // dies — verified on this machine, including under SIGKILL — but a
        // clean quit should not rely on that.
        externalOnly = false
        if !InternalDisplay.builtinIsActive() { InternalDisplay.enable(attempts: 3) }
    }

    // MARK: - Built-in display

    /// Single entry point for every display decision. Idempotent against
    /// observed state, so the disable -> reconfiguration -> settle -> reconcile
    /// path terminates after one pass instead of oscillating.
    private func reconcileDisplay() {
        guard !reconcilingDisplay else { return }

        let snapshot = DisplaySnapshot(
            builtinActive: InternalDisplay.builtinIsActive(),
            externalActive: InternalDisplay.activeExternalCount(),
            // Cross-check against the helper's own IOKit count: CoreGraphics
            // happily reports a Sidecar iPad or an AirPlay screen as external,
            // and neither is something you can count on still being there.
            physicalExternalConfirmed: (lastStatus?.externalDisplays ?? -1) >= 1,
            lidClosed: InternalDisplay.lidClosed(),
            mechanismAvailable: InternalDisplay.isAvailable,
            disableFailures: disableFailures)

        let (action, reason) = DisplayPolicy.decide(externalOnly: externalOnly, snapshot)
        displayReason = reason
        guard action != .none else { return }

        reconcilingDisplay = true
        defer {
            // Let the reconfiguration callbacks land before accepting another
            // decision, so a settle triggered by our own change is a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reconcilingDisplay = false
            }
        }

        switch action {
        case .enable:
            if InternalDisplay.enable(attempts: 3) {
                disableFailures = 0
            } else {
                displayReason = "could not turn the built-in display back on"
            }
        case .disable:
            if InternalDisplay.disable() {
                disableFailures = 0
            } else {
                disableFailures += 1
                externalOnly = disableFailures < DisplayPolicy.maxDisableFailures
            }
        case .none:
            break
        }
        updateIcon(armed: lastStatus?.armed == true)
    }

    /// Asks for confirmation on the display the user can still see, and reverts
    /// on its own if nobody answers.
    ///
    /// This exists for the one failure with no automatic detection: the external
    /// going dark without disconnecting — a monitor input switch, a KVM, or its
    /// own power button on a link that stays up. No event fires, so no code
    /// runs, and both panels are black. A countdown is the only thing that
    /// recovers it, and it is the same pattern macOS uses for resolution
    /// changes.
    private func confirmEngagement() {
        guard !UserDefaults.standard.bool(forKey: Key.skipDisplayConfirmation) else { return }

        let alert = NSAlert()
        alert.messageText = "Using the external display only"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Turn Built-in Back On")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        var remaining = 15
        alert.informativeText = "Reverting in \(remaining) seconds if you can't see this."
        let countdown = Timer(timeInterval: 1, repeats: true) { timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                NSApp.abortModal()
            } else {
                alert.informativeText = "Reverting in \(remaining) seconds if you can't see this."
            }
        }
        // .common so it keeps firing inside the modal run loop.
        RunLoop.main.add(countdown, forMode: .common)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        countdown.invalidate()

        if response == .alertFirstButtonReturn {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Key.skipDisplayConfirmation)
            }
        } else {
            externalOnly = false
            reconcileDisplay()
        }
    }

    // MARK: - Talking to the helper

    /// Single place that decides what to ask for. Called on every display
    /// change, every toggle, and every heartbeat.
    private func push() {
        let external = DisplayWatcher.shared.externalCount
        let request: Wire.Request = (keepAwake && external > 0)
            ? .arm(external: external, batteryFloor: batteryFloor)
            : .disarm
        client.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let status):
                self.helperReachable = true
                self.lastStatus = status
                self.updateIcon(armed: status.armed)
            case .failure:
                self.helperReachable = false
                self.lastStatus = nil
                self.updateIcon(armed: false)
            }
        }
    }

    private func updateIcon(armed: Bool) {
        // Both symbols predate the 13.0 deployment target. `lid.open` and
        // `clamshell` do not exist as SF Symbols — do not reach for them.
        let name = armed ? "laptopcomputer" : "moon.zzz"
        let description = armed ? "Staying awake with the lid closed" : "Normal sleep"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    /// Rebuilt on open rather than on a timer — it only needs to be right at
    /// the moment someone is looking at it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(informationItem())
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Keep awake with lid closed",
                                action: #selector(toggleKeepAwake), keyEquivalent: "")
        toggle.target = self
        toggle.state = keepAwake ? .on : .off
        menu.addItem(toggle)

        let floor = NSMenuItem(title: "Restore sleep below \(Self.defaultBatteryFloor)% battery",
                               action: #selector(toggleBatteryFloor), keyEquivalent: "")
        floor.target = self
        floor.state = batteryFloor > 0 ? .on : .off
        menu.addItem(floor)

        menu.addItem(.separator())

        let externalOnlyItem = NSMenuItem(title: "Use external display only",
                                          action: #selector(toggleExternalOnly), keyEquivalent: "")
        externalOnlyItem.target = self
        externalOnlyItem.state = externalOnly ? .on : .off
        externalOnlyItem.isEnabled = InternalDisplay.isAvailable
            && !InternalDisplay.lidClosed()
            && (externalOnly || DisplayWatcher.shared.externalCount > 0)
        menu.addItem(externalOnlyItem)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let escape = NSMenuItem(title: "Copy emergency reset command",
                                action: #selector(copyEscapeHatch), keyEquivalent: "")
        escape.target = self
        menu.addItem(escape)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func informationItem() -> NSMenuItem {
        let text: String
        if !helperReachable {
            text = "Helper not running — see README"
        } else {
            let external = DisplayWatcher.shared.externalCount
            let battery = PowerInfo.batteryPercent().map { "\($0)%" } ?? "—"
            let power = PowerInfo.onAC() ? "AC" : "battery"
            var state = lastStatus?.armed == true ? "active" : "off"
            if let reason = lastStatus?.reason, !reason.isEmpty, keepAwake {
                state = "off — \(reason)"
            }
            var builtin = InternalDisplay.builtinIsActive() ? "built-in on" : "built-in off"
            if !displayReason.isEmpty { builtin += " — \(displayReason)" }
            text = "\(external) external · \(builtin) · \(battery) on \(power) · Lid-closed mode: \(state)"
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
        push()
    }

    @objc private func toggleExternalOnly() {
        externalOnly.toggle()
        let wasActive = InternalDisplay.builtinIsActive()
        reconcileDisplay()
        if externalOnly, wasActive, !InternalDisplay.builtinIsActive() { confirmEngagement() }
    }

    @objc private func toggleBatteryFloor() {
        batteryFloor = batteryFloor > 0 ? 0 : Self.defaultBatteryFloor
        push()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    /// The documented way out if this tool ever fails with the flag set.
    @objc private func copyEscapeHatch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo pmset -a disablesleep 0", forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
