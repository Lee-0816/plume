import AppKit
import WebKit

/// Developer hook for scripted smoke tests. Inactive unless the app is
/// launched with `-PlumeAutomation "step ;; step ;; …"`. Steps:
///   open:<path>      open a document
///   js:<expr>        evaluate `return <expr>` in the editor, print result
///   action:<sel>     send an action through the responder chain
///   snap:<path>      write a PNG of the key editor window
///   key:<chars>      not supported (needs accessibility); use js:/action:
///   wait:<seconds>   pause
///   quit             terminate
enum DebugAutomation {
    static func runIfRequested() {
        guard let script = UserDefaults.standard.string(forKey: "PlumeAutomation") else { return }
        let steps = script.components(separatedBy: ";;")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        NSApp.activate(ignoringOtherApps: true)
        run(steps, 0)
    }

    static func log(_ text: String) {
        let line = ("[automation] " + text + "\n").data(using: .utf8)!
        FileHandle.standardError.write(line)
        if let path = UserDefaults.standard.string(forKey: "PlumeAutomationLog") {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        }
    }

    private static var controller: EditorWindowController? {
        if let c = NSApp.keyWindow?.windowController as? EditorWindowController { return c }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? EditorWindowController }.first
    }

    private static func run(_ steps: [String], _ index: Int) {
        guard index < steps.count else { return }
        let step = steps[index]
        let next = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run(steps, index + 1) } }
        log("step \(index + 1): \(step.prefix(120))")
        if step.hasPrefix("open:") {
            let url = URL(fileURLWithPath: String(step.dropFirst(5)))
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { log("open failed: \(error)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(steps, index + 1) }
            }
        } else if step.hasPrefix("js:") {
            guard let controller else { log("no editor window"); next(); return }
            controller.editor.call(String(step.dropFirst(3))) { value in
                log("result: \(String(describing: value ?? "nil").prefix(2000))")
                next()
            }
        } else if step.hasPrefix("action:") {
            controller?.window?.makeKeyAndOrderFront(nil)
            let ok = NSApp.sendAction(Selector(String(step.dropFirst(7))), to: nil, from: nil)
            log("action handled: \(ok)")
            next()
        } else if step.hasPrefix("snap:") {
            guard let controller else { log("no editor window"); next(); return }
            snapshot(controller, to: String(step.dropFirst(5)), done: next)
        } else if step.hasPrefix("pdf:") {
            guard let controller, let document = controller.markdownDocument, let window = controller.window else { next(); return }
            let url = URL(fileURLWithPath: String(step.dropFirst(4)))
            controller.editor.renderForExport { _ in
                do {
                    let op = try document.printOperation(withSettings: [
                        .jobDisposition: NSPrintInfo.JobDisposition.save,
                        .jobSavingURL: url,
                    ])
                    op.showsPrintPanel = false
                    op.showsProgressPanel = true
                    op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        log("pdf exists: \(FileManager.default.fileExists(atPath: url.path))")
                        run(steps, index + 1)
                    }
                } catch {
                    log("pdf failed: \(error)")
                    next()
                }
            }
        } else if step.hasPrefix("html:") {
            guard let controller else { next(); return }
            let url = URL(fileURLWithPath: String(step.dropFirst(5)))
            controller.editor.renderForExport { body in
                let html = HTMLExporter.document(title: "export", body: body ?? "")
                try? html.write(to: url, atomically: true, encoding: .utf8)
                log("html bytes: \(html.utf8.count)")
                next()
            }
        } else if step.hasPrefix("find:") || step.hasPrefix("replace:") {
            guard let controller else { next(); return }
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let args = parts[1].components(separatedBy: "=>")
            controller.findBar.searchField.stringValue = args[0]
            if parts[0] == "find" {
                controller.findBar(controller.findBar, search: args[0], backwards: false, incremental: false)
            } else {
                controller.findBar(controller.findBar, replace: args[0], with: args.count > 1 ? args[1] : "")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run(steps, index + 1) }
        } else if step.hasPrefix("probe:") {
            let sel = Selector(String(step.dropFirst(6)))
            let target = NSApp.target(forAction: sel, to: nil, from: nil)
            log("target for \(sel): \(String(describing: target)) firstResponder=\(String(describing: NSApp.keyWindow?.firstResponder))")
            next()
        } else if step.hasPrefix("key:") {
            sendKey(String(step.dropFirst(4)))
            next()
        } else if step.hasPrefix("menu:") || step.hasPrefix("menukey:") {
            // Resolve the item by title path or by shortcut, then dispatch it
            // through this window's responder chain (the app may be inactive
            // when launched from a script, so AppKit's own routing is skipped).
            let item: NSMenuItem?
            if step.hasPrefix("menu:") {
                item = findItem(path: step.dropFirst(5).components(separatedBy: "/"))
            } else {
                item = findItem(shortcut: String(step.dropFirst(8)))
            }
            guard let item, let action = item.action else { log("menu item not found"); next(); return }
            guard let target = resolveTarget(action) else { log("no responder for \(action)"); next(); return }
            var enabled = true
            if let validator = target as? NSMenuItemValidation { enabled = validator.validateMenuItem(item) }
            log("menu '\(item.title)' → \(type(of: target)) enabled=\(enabled)")
            if enabled { _ = (target as AnyObject).perform(action, with: item) }
            next()
        } else if step.hasPrefix("wait:") {
            let seconds = Double(step.dropFirst(5)) ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { run(steps, index + 1) }
        } else if step == "quit" {
            NSApp.terminate(nil)
        } else {
            log("unknown step")
            next()
        }
    }

    private static func findItem(path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        for (i, title) in path.enumerated() {
            guard let item = menu?.items.first(where: { $0.title == title }) else { return nil }
            if i == path.count - 1 { return item }
            menu = item.submenu
        }
        return nil
    }

    private static func findItem(shortcut spec: String) -> NSMenuItem? {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().components(separatedBy: "+") {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            case "f8": key = String(Character(UnicodeScalar(NSF8FunctionKey)!))
            case "f9": key = String(Character(UnicodeScalar(NSF9FunctionKey)!))
            default: key = part
            }
        }
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let found = search(sub) { return found }
                let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if item.keyEquivalent.lowercased() == key && mask == flags { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// Walk first responder → … → window → delegate → app → app delegate → document controller.
    private static func resolveTarget(_ action: Selector) -> Any? {
        let window = controller?.window
        var responder: NSResponder? = window?.firstResponder
        while let r = responder {
            if r.responds(to: action) { return r }
            responder = r.nextResponder
        }
        for candidate in [window?.delegate as AnyObject?, window?.windowController?.document, NSApp, NSApp.delegate as AnyObject?, NSDocumentController.shared] {
            if let c = candidate, c.responds(to: action) { return c }
        }
        return nil
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "/": 44, "n": 45, "m": 46, "`": 50, "f8": 100, "f9": 101,
    ]

    /// Synthesise a key press inside this process, e.g. "cmd+b", "ctrl+cmd+s", "f8".
    private static func sendKey(_ spec: String) {
        guard let window = controller?.window else { return }
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().components(separatedBy: "+") {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = part
            }
        }
        guard let code = keyCodes[key] else { log("unknown key \(key)"); return }
        var chars = key
        if key == "f8" { chars = String(Character(UnicodeScalar(NSF8FunctionKey)!)); flags.insert(.function) }
        if key == "f9" { chars = String(Character(UnicodeScalar(NSF9FunctionKey)!)); flags.insert(.function) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func snapshot(_ controller: EditorWindowController, to path: String, done: @escaping () -> Void) {
        guard let content = controller.window?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            done()
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let webView = controller.editor.webView!
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
            let size = content.bounds.size
            let final = NSImage(size: size)
            final.lockFocus()
            if let cg = rep.cgImage {
                NSImage(cgImage: cg, size: size).draw(in: content.bounds)
            }
            if let image {
                let frame = webView.convert(webView.bounds, to: content)
                image.draw(in: frame)
            }
            final.unlockFocus()
            if let tiff = final.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                log("snapshot saved \(path)")
            }
            done()
        }
    }
}
