import AppKit

// Keep AppKit from appending its own Dictation / Emoji items to the Edit menu;
// the menu we build adds an "Emoji & Symbols" item itself.
UserDefaults.standard.register(defaults: [
    "NSDisabledDictationMenuItem": true,
    "NSDisabledCharacterPaletteMenuItem": true,
])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
