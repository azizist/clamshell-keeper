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
    }
    private static let defaultBatteryFloor = 20

    private let client = DaemonClient()
    private var statusItem: NSStatusItem!
    private var heartbeat: Timer?
    private var lastStatus: Wire.Status?
    private var helperReachable = true

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

        DisplayWatcher.shared.start { [weak self] _ in self?.push() }

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
            text = "Display: \(external) external · \(battery) on \(power) · Lid-closed mode: \(state)"
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
