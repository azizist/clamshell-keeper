import AppKit

// ClamshellKeeper — menu bar front end. Holds no privilege and makes no
// decisions the root helper is not free to override or revoke.

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
