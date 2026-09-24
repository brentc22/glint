import AppKit

let app = NSApplication.shared
// Accessory: no Dock icon; a menu bar item and global shortcuts instead.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
