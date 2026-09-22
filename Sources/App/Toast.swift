import AppKit

/// A small banner near the top of the screen that fades itself away.
///
/// Deliberately not UNUserNotificationCenter. That needs a TCC grant this app
/// cannot reliably get: an ad-hoc-signed build is refused outright with
/// "Notifications are not allowed for this application" from a normal path, and
/// from /Applications the authorization callback never returns at all. A
/// message the user might never see is worse than no message, and this one is
/// usually explaining why something they just pressed did nothing.
///
/// Needs no permission, steals no focus, and cannot fail.
enum Toast {

    private static var panel: NSPanel?
    private static var dismissal: DispatchWorkItem?

    static func show(_ text: String, for seconds: TimeInterval = 2.5) {
        dismissal?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let padding = NSSize(width: 28, height: 18)
        let size = NSSize(width: label.frame.width + padding.width * 2,
                          height: label.frame.height + padding.height)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: padding.width, y: padding.height / 2)
        background.addSubview(label)

        // .nonactivatingPanel keeps the app in the background: this is an
        // aside, not something to interrupt what the user is doing.
        let hud = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        hud.contentView = background
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.level = .statusBar
        hud.ignoresMouseEvents = true
        hud.hasShadow = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Whichever screen has focus — which, when the built-in is the only one
        // left, is the built-in.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                       y: frame.maxY - size.height - 12))
        }

        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hud.animator().alphaValue = 1
        }
        panel = hud

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.orderOut(nil)
                if panel === hud { panel = nil }
            })
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
