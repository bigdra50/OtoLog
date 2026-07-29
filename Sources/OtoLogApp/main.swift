import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement=true の保険。メニューバー常駐のみで Dock には出さない
app.setActivationPolicy(.accessory)
app.run()
