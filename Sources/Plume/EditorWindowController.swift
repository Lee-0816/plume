import AppKit
import UniformTypeIdentifiers
import WebKit

/// One editor window: sidebar + editor + find bar + status bar.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    EditorViewDelegate, SidebarDelegate, FindBarDelegate {

    let editor = EditorViewController()
    let sidebar = SidebarViewController()
    private let statusBar = StatusBarView()
    let findBar = FindBarView()
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var sidebarObservation: NSKeyValueObservation?
    private var settingsObserver: NSObjectProtocol?

    private(set) var rootFolder: URL? {
        didSet { sidebar.setRoot(rootFolder) }
    }

    var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    private var documentFolder: URL? { markdownDocument?.fileURL?.deletingLastPathComponent() }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 520, height: 360)
        window.backgroundColor = Palette.editorBackground
        window.tabbingIdentifier = "PlumeEditor"
        window.identifier = NSUserInterfaceItemIdentifier("PlumeEditorWindow")
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        buildLayout()
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        windowFrameAutosaveName = "PlumeEditorWindow"

        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.window?.backgroundColor = Palette.editorBackground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func buildLayout() {
        editor.delegate = self
        sidebar.delegate = self
        findBar.delegate = self
        findBar.isHidden = true

        let main = NSViewController()
        let container = EditorBackgroundView(frame: NSRect(x: 0, y: 0, width: 860, height: 760))
        main.view = container
        main.addChild(editor)

        let stack = NSStackView(views: [findBar, editor.view, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        for v in [findBar, editor.view, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        editor.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        statusBar.onToggleSidebar = { [weak self] in self?.toggleSidebarPane() }
        statusBar.onToggleSource = { [weak self] in self?.editor.toggleSourceMode() }

        sidebar.view.frame.size.width = Settings.shared.sidebarWidth
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !Settings.shared.sidebarVisible
        let contentItem = NSSplitViewItem(viewController: main)
        contentItem.minimumThickness = 360
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        contentViewController = splitController

        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            Settings.shared.sidebarVisible = !item.isCollapsed
            if !item.isCollapsed, let width = self?.sidebar.view.frame.width, width > 0 {
                Settings.shared.sidebarWidth = width
            }
        }
    }

    // MARK: Document binding

    override var document: AnyObject? {
        didSet {
            guard let doc = markdownDocument else { return }
            if let preferred = doc.preferredRootFolder {
                rootFolder = preferred
                doc.preferredRootFolder = nil
            } else if let folder = doc.fileURL?.deletingLastPathComponent(), !isInsideRoot(doc.fileURL) {
                rootFolder = folder
            }
            loadDocumentIntoEditor()
            sidebar.highlight(doc.fileURL)
        }
    }

    private func isInsideRoot(_ url: URL?) -> Bool {
        guard let url, let rootFolder else { return false }
        return url.standardizedFileURL.path.hasPrefix(rootFolder.standardizedFileURL.path + "/")
    }

    private func loadDocumentIntoEditor() {
        guard let doc = markdownDocument else { return }
        editor.load(markdown: doc.markdown, baseFolder: documentFolder)
    }

    /// Called after the document re-read its file (revert or external change).
    func documentDidReload() {
        guard let doc = markdownDocument else { return }
        editor.reload(markdown: doc.markdown)
    }

    /// Called when the document was saved to, renamed or moved to a new place.
    func documentLocationDidChange() {
        editor.setBaseFolder(documentFolder)
        if rootFolder == nil || !isInsideRoot(markdownDocument?.fileURL) {
            if let folder = documentFolder { rootFolder = folder }
        }
        sidebar.reloadTree(keepExpansion: true)
        sidebar.highlight(markdownDocument?.fileURL)
    }

    func setRootFolder(_ url: URL) {
        rootFolder = url
        showSidebar(tab: .files)
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        sidebar.stopWatching()
        sidebarObservation = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window {
            editor.focusEditor()
        }
    }

    // MARK: EditorViewDelegate

    func editorDidBecomeReady(_ editor: EditorViewController) {
        loadDocumentIntoEditor()
        window?.makeFirstResponder(editor.webView)
    }

    func editor(_ editor: EditorViewController, didChange markdown: String, stats: TextStats) {
        markdownDocument?.editorDidChange(markdown)
        statusBar.update(stats: stats)
    }

    func editorDidBecomeDirty(_ editor: EditorViewController) {
        markdownDocument?.editorDidBecomeDirty()
    }

    func editor(_ editor: EditorViewController, didUpdateStats stats: TextStats) {
        statusBar.update(stats: stats)
    }

    func editor(_ editor: EditorViewController, didUpdateOutline items: [OutlineItem]) {
        sidebar.setOutline(items)
    }

    func editor(_ editor: EditorViewController, didRequestOpen link: String) {
        openLink(link)
    }

    func editor(_ editor: EditorViewController, didReceive files: [IncomingFile]) {
        saveIncomingFiles(files)
    }

    func editor(_ editor: EditorViewController, didSwitchMode mode: String) {
        statusBar.update(mode: mode)
    }

    func editor(_ editor: EditorViewController, didTriggerShortcut name: String) {
        switch name {
        case "focus": toggleFocusMode(nil)
        case "typewriter": toggleTypewriterMode(nil)
        default: break
        }
    }

    // MARK: SidebarDelegate

    func sidebar(_ sidebar: SidebarViewController, didSelectFile url: URL) {
        openInThisWindow(url)
    }

    func sidebar(_ sidebar: SidebarViewController, didSelectHeadingAt index: Int) {
        editor.scrollToHeading(at: index)
    }

    func sidebarRequestsOpenFolder(_ sidebar: SidebarViewController) {
        openFolder(nil)
    }

    func sidebar(_ sidebar: SidebarViewController, didRename url: URL, to newURL: URL) {
        // NSDocument follows coordinated moves itself; refresh our view of it.
        if markdownDocument?.fileURL?.standardizedFileURL == url.standardizedFileURL {
            markdownDocument?.fileURL = newURL
        }
    }

    // MARK: Opening files

    /// Open a Markdown file in this window, replacing the current document
    /// (after saving it), like a single-window editor.
    func openInThisWindow(_ url: URL) {
        let controller = NSDocumentController.shared
        if let existing = controller.document(for: url) {
            existing.showWindows()
            return
        }
        guard let current = markdownDocument else { return }
        let replaceable = current.fileURL != nil || (!current.isDocumentEdited && current.markdown.isEmpty)
        guard replaceable else {
            openInNewWindow(url)
            return
        }
        current.flushEditor { [weak self] in
            let proceed = {
                controller.openDocument(withContentsOf: url, display: false) { newDocument, alreadyOpen, error in
                    guard let self else { return }
                    if let error {
                        self.presentError(error)
                        self.sidebar.highlight(current.fileURL)
                        return
                    }
                    guard let newDocument = newDocument as? MarkdownDocument else { return }
                    if alreadyOpen && !newDocument.windowControllers.isEmpty {
                        newDocument.showWindows()
                        return
                    }
                    self.swap(to: newDocument, from: current)
                }
            }
            if current.isDocumentEdited, current.fileURL != nil {
                current.autosave(withImplicitCancellability: false) { _ in proceed() }
            } else {
                proceed()
            }
        }
    }

    private func swap(to newDocument: MarkdownDocument, from oldDocument: MarkdownDocument) {
        oldDocument.removeWindowController(self)
        newDocument.addWindowController(self)
        oldDocument.close()
        synchronizeWindowTitleWithDocumentName()
        window?.makeFirstResponder(editor.webView)
    }

    private func openInNewWindow(_ url: URL) {
        let root = rootFolder
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
            if let error {
                NSApp.presentError(error)
                return
            }
            guard let document = document as? MarkdownDocument else { return }
            if document.windowControllers.isEmpty {
                document.preferredRootFolder = root
                document.makeWindowControllers()
            }
            document.showWindows()
        }
    }

    private func openLink(_ raw: String) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !link.hasPrefix("#") else { return }
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme != "file", scheme.count > 1 {
            NSWorkspace.shared.open(url)
            return
        }
        var target: URL
        if let url = URL(string: link), url.scheme?.lowercased() == "file" {
            target = url
        } else {
            var path = link.removingPercentEncoding ?? link
            if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
            if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
            if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
            if path.hasPrefix("/") {
                target = URL(fileURLWithPath: path)
            } else {
                let base = documentFolder ?? FileManager.default.homeDirectoryForCurrentUser
                target = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
            }
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            NSSound.beep()
            return
        }
        if MarkdownDocument.markdownExtensions.contains(target.pathExtension.lowercased()) {
            openInThisWindow(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    // MARK: Images and attachments

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "heic", "avif"]

    /// Where pasted images go: `assets/` next to the document, or a shared
    /// folder for documents that were never saved.
    private func imageFolder() -> (folder: URL, relative: Bool) {
        if let folder = documentFolder {
            return (folder.appendingPathComponent("assets", isDirectory: true), true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return (support.appendingPathComponent("Plume/Images", isDirectory: true), false)
    }

    private static func markdownPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>()[] ").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "image" : cleaned
    }

    private static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func timestampName(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "image-\(formatter.string(from: Date())).\(ext)"
    }

    private func saveIncomingFiles(_ files: [IncomingFile]) {
        let (folder, relative) = imageFolder()
        var items: [[String: Any]] = []
        var skipped = 0
        for file in files {
            var ext = (file.name as NSString).pathExtension.lowercased()
            if ext.isEmpty, let type = UTType(mimeType: file.mimeType), let preferred = type.preferredFilenameExtension {
                ext = preferred
            }
            guard file.mimeType.hasPrefix("image/") || EditorWindowController.imageExtensions.contains(ext) else {
                skipped += 1
                continue
            }
            if ext.isEmpty { ext = "png" }
            let stem = (file.name as NSString).deletingPathExtension
            let genericName = stem.isEmpty || stem.lowercased() == "image" || stem.lowercased().hasPrefix("screenshot")
            let fileName = genericName
                ? EditorWindowController.timestampName(ext: ext)
                : EditorWindowController.sanitizedFileName(stem) + "." + ext
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = EditorWindowController.uniqueURL(in: folder, fileName: fileName)
                try file.data.write(to: destination, options: .atomic)
                let path = relative ? "assets/" + destination.lastPathComponent : destination.path
                items.append([
                    "image": true,
                    "alt": (destination.lastPathComponent as NSString).deletingPathExtension,
                    "path": EditorWindowController.markdownPath(path),
                ])
            } catch {
                presentError(error)
                return
            }
        }
        editor.insertFiles(items)
        if skipped > 0 && items.isEmpty {
            NSSound.beep()
        }
    }

    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要插入的图片"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.insertImageFiles(panel.urls)
        }
    }

    private func insertImageFiles(_ urls: [URL]) {
        let (folder, relative) = imageFolder()
        var items: [[String: Any]] = []
        for url in urls {
            var path: String
            if let docFolder = documentFolder, url.standardizedFileURL.path.hasPrefix(docFolder.standardizedFileURL.path + "/") {
                // Already beside the document: link it in place.
                path = String(url.standardizedFileURL.path.dropFirst(docFolder.standardizedFileURL.path.count + 1))
            } else if relative {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = EditorWindowController.sanitizedFileName((url.lastPathComponent as NSString).deletingPathExtension)
                        + "." + url.pathExtension.lowercased()
                    let destination = EditorWindowController.uniqueURL(in: folder, fileName: name)
                    try FileManager.default.copyItem(at: url, to: destination)
                    path = "assets/" + destination.lastPathComponent
                } catch {
                    presentError(error)
                    return
                }
            } else {
                path = url.path
            }
            items.append([
                "image": true,
                "alt": (url.lastPathComponent as NSString).deletingPathExtension,
                "path": EditorWindowController.markdownPath(path),
            ])
        }
        editor.insertFiles(items)
    }

    // MARK: Menu actions

    @objc func formatCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        window?.makeFirstResponder(editor.webView)
        editor.command(name)
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        editor.toggleSourceMode()
    }

    @objc func showOutline(_ sender: Any?) {
        showSidebar(tab: .outline)
    }

    @objc func showFileTree(_ sender: Any?) {
        showSidebar(tab: .files)
    }

    @objc func toggleSidebarPane(_ sender: Any? = nil) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    private func showSidebar(tab: SidebarViewController.Tab) {
        if sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
        } else if sidebar.tab == tab {
            sidebarItem.animator().isCollapsed = true
            return
        }
        sidebar.tab = tab
        Settings.shared.sidebarTab = tab.rawValue
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        Settings.shared.focusMode.toggle()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        Settings.shared.typewriterMode.toggle()
    }

    @objc func zoomInText(_ sender: Any?) {
        Settings.shared.zoom = (Settings.shared.zoom + 0.1).rounded(toPlaces: 1)
    }

    @objc func zoomOutText(_ sender: Any?) {
        Settings.shared.zoom = (Settings.shared.zoom - 0.1).rounded(toPlaces: 1)
    }

    @objc func actualSizeText(_ sender: Any?) {
        Settings.shared.zoom = 1.0
    }

    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要在侧边栏中显示的文件夹"
        panel.directoryURL = rootFolder ?? documentFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setRootFolder(url)
        }
    }

    @objc func plumePasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        window?.makeFirstResponder(editor.webView)
        editor.insertMarkdown(text)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Export

    @objc func exportHTML(_ sender: Any?) {
        guard let window, let doc = markdownDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (doc.displayName as NSString).deletingPathExtension + ".html"
        panel.directoryURL = documentFolder
        panel.message = "导出为 HTML（图片使用相对路径，建议导出到文档所在文件夹）"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.editor.renderForExport { body in
                guard let body else {
                    NSSound.beep()
                    return
                }
                let title = (doc.displayName as NSString).deletingPathExtension
                let html = HTMLExporter.document(title: title, body: body)
                do {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    // MARK: Find

    @objc func plumeFind(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: showFindBar(replace: false)
        case 2: showFindBar(replace: true)
        case 3: findAgain(backwards: false)
        case 4: findAgain(backwards: true)
        case 5: useSelectionForFind()
        default: break
        }
    }

    private func showFindBar(replace: Bool) {
        findBar.showsReplace = replace
        findBar.isHidden = false
        findBar.focusSearch()
        if !findBar.query.isEmpty {
            updateMatchCount()
        }
    }

    private func findAgain(backwards: Bool) {
        if findBar.query.isEmpty {
            showFindBar(replace: false)
            return
        }
        findBar(findBar, search: findBar.query, backwards: backwards, incremental: false)
    }

    private func useSelectionForFind() {
        editor.selectedText { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.findBar.searchField.stringValue = text
            self.findBar.isHidden = false
            self.updateMatchCount()
        }
    }

    private func updateMatchCount() {
        let query = findBar.query
        guard !query.isEmpty else {
            findBar.setMatchCount(nil)
            return
        }
        editor.call("Plume.countMatches(q, cs)", ["q": query, "cs": findBar.caseSensitive]) { [weak self] value in
            self?.findBar.setMatchCount((value as? NSNumber)?.intValue)
        }
    }

    func findBar(_ bar: FindBarView, search query: String, backwards: Bool, incremental: Bool) {
        guard !query.isEmpty else {
            bar.setMatchCount(nil)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = bar.caseSensitive
        configuration.wraps = true
        let run = { [weak self] in
            self?.editor.webView.find(query, configuration: configuration) { _ in }
            self?.updateMatchCount()
        }
        if incremental {
            editor.call("Plume.collapseSelection()") { _ in run() }
        } else {
            run()
        }
    }

    func findBar(_ bar: FindBarView, replace query: String, with replacement: String) {
        guard !query.isEmpty else { return }
        editor.call("Plume.replaceSelection(q, r, cs)", ["q": query, "r": replacement, "cs": bar.caseSensitive]) { [weak self] _ in
            guard let self else { return }
            self.findBar(bar, search: query, backwards: false, incremental: false)
            self.window?.makeFirstResponder(bar.replaceField)
        }
    }

    func findBar(_ bar: FindBarView, replaceAll query: String, with replacement: String) {
        guard !query.isEmpty else { return }
        editor.call("Plume.replaceAll(q, r, cs)", ["q": query, "r": replacement, "cs": bar.caseSensitive]) { [weak self] value in
            let count = (value as? NSNumber)?.intValue ?? 0
            if count == 0 { NSSound.beep() }
            self?.updateMatchCount()
        }
    }

    func findBarDidClose(_ bar: FindBarView) {
        bar.isHidden = true
        editor.focusEditor()
    }

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSourceMode(_:)):
            menuItem.state = editor.mode == "sv" ? .on : .off
        case #selector(toggleFocusMode(_:)):
            menuItem.state = Settings.shared.focusMode ? .on : .off
        case #selector(toggleTypewriterMode(_:)):
            menuItem.state = Settings.shared.typewriterMode ? .on : .off
        case #selector(toggleSidebarPane(_:)):
            menuItem.title = sidebarItem.isCollapsed ? "显示侧边栏" : "隐藏侧边栏"
        case #selector(showOutline(_:)):
            menuItem.state = !sidebarItem.isCollapsed && sidebar.tab == .outline ? .on : .off
        case #selector(showFileTree(_:)):
            menuItem.state = !sidebarItem.isCollapsed && sidebar.tab == .files ? .on : .off
        case #selector(revealInFinder(_:)):
            return markdownDocument?.fileURL != nil
        case #selector(formatCommand(_:)), #selector(insertImage(_:)), #selector(exportHTML(_:)):
            return editor.isReady
        default:
            break
        }
        return true
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
