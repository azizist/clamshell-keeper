import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut for the external-display toggle.
///
/// Carbon's RegisterEventHotKey is used rather than an NSEvent global monitor
/// or a CGEventTap because it needs no Accessibility permission — the app can
/// claim the key the moment it launches, with no prompt and nothing for the
/// user to grant.
///
/// The shortcut doubles as the blind-recovery key: if the built-in panel is off
/// and the external has gone dark, pressing it toggles the panel back on
/// without needing to see a menu. That is why it is two modifiers rather than
/// three — it has to be hittable by touch.
enum Hotkey {

    /// ⌃⌥D
    static let displayName = "⌃⌥D"

    private static var reference: EventHotKeyRef?
    private static var action: (() -> Void)?

    @discardableResult
    static func register(_ action: @escaping () -> Void) -> Bool {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x434B_4859), id: 1)   // 'CKHY'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D),
                                         UInt32(controlKey | optionKey),
                                         id, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            // Whoever registered it first wins, and there is no way to find out
            // who. Say so in the menu rather than failing silently.
            NSLog("ClamshellKeeper: could not register \(displayName) (status \(status)) — another app may own it")
        }
        return status == noErr
    }
}
