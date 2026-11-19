import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.shared.applyAppearance()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugAutomation.runIfRequested()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.string(forKey: "PlumeAutomation") == nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "一个所见即所得的 Markdown 编辑器。\n编辑引擎基于 Vditor（MIT 许可证）。",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Plume",
            .credits: credits,
        ])
    }

    /// ⌘Q: pull the latest text out of every editor before AppKit autosaves.
    @objc func quitAfterFlushing(_ sender: Any?) {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
        let group = DispatchGroup()
        for document in documents {
            group.enter()
            document.flushEditor { group.leave() }
        }
        group.notify(queue: .main) {
            NSApp.terminate(sender)
        }
    }

    @objc func openFolder(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            controller.openFolder(sender)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            guard let markdown = document as? MarkdownDocument else { return }
            markdown.preferredRootFolder = url
            markdown.makeWindowControllers()
            markdown.showWindows()
            markdown.editorWindowController?.setRootFolder(url)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        let modes: [AppearanceMode] = [.system, .light, .dark]
        guard modes.indices.contains(sender.tag) else { return }
        Settings.shared.appearance = modes[sender.tag]
    }

    @objc func openMarkdownReference(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "Welcome", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        do {
            let controller = NSDocumentController.shared
            let document = try controller.makeUntitledDocument(ofType: MarkdownDocument.markdownType)
            guard let markdown = document as? MarkdownDocument else { return }
            markdown.setInitialContent(text)
            controller.addDocument(markdown)
            markdown.makeWindowControllers()
            markdown.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setAppearanceMode(_:)) {
            let modes: [AppearanceMode] = [.system, .light, .dark]
            menuItem.state = modes.indices.contains(menuItem.tag) && modes[menuItem.tag] == Settings.shared.appearance ? .on : .off
        }
        return true
    }
}
