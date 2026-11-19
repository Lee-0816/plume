import AppKit

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
}

/// App-wide preferences stored in UserDefaults.
final class Settings {
    static let shared = Settings()
    /// Posted when a setting that open editors care about changes.
    static let didChange = Notification.Name("PlumeSettingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "appearance": AppearanceMode.system.rawValue,
            "focusMode": false,
            "typewriterMode": false,
            "zoom": 1.0,
            "sidebarVisible": true,
            "sidebarTab": 0,
            "sidebarWidth": 250.0,
        ])
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearance")
            applyAppearance()
            notify()
        }
    }

    var focusMode: Bool {
        get { defaults.bool(forKey: "focusMode") }
        set { defaults.set(newValue, forKey: "focusMode"); notify() }
    }

    var typewriterMode: Bool {
        get { defaults.bool(forKey: "typewriterMode") }
        set { defaults.set(newValue, forKey: "typewriterMode"); notify() }
    }

    var zoom: Double {
        get { min(2.0, max(0.6, defaults.double(forKey: "zoom"))) }
        set { defaults.set(min(2.0, max(0.6, newValue)), forKey: "zoom"); notify() }
    }

    /// Remembered for new windows only; does not affect open windows.
    var sidebarVisible: Bool {
        get { defaults.bool(forKey: "sidebarVisible") }
        set { defaults.set(newValue, forKey: "sidebarVisible") }
    }

    /// 0 = file tree, 1 = outline. Remembered for new windows only.
    var sidebarTab: Int {
        get { defaults.integer(forKey: "sidebarTab") }
        set { defaults.set(newValue, forKey: "sidebarTab") }
    }

    var sidebarWidth: CGFloat {
        get { CGFloat(min(420, max(180, defaults.double(forKey: "sidebarWidth")))) }
        set { defaults.set(Double(newValue), forKey: "sidebarWidth") }
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }
}

enum Palette {
    /// Matches --plume-bg in theme.css so the title bar blends into the page.
    static let editorBackground = NSColor(name: "PlumeEditorBackground") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x22 / 255.0, alpha: 1)
        }
        return NSColor.white
    }

    static let hairline = NSColor(name: "PlumeHairline") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1, alpha: 0.08)
        }
        return NSColor(white: 0, alpha: 0.08)
    }
}
