import AppKit
import WebKit

struct TextStats {
    var words = 0
    var chars = 0
    var lines = 0

    init() {}

    init(_ dict: Any?) {
        let d = dict as? [String: Any] ?? [:]
        words = (d["words"] as? NSNumber)?.intValue ?? 0
        chars = (d["chars"] as? NSNumber)?.intValue ?? 0
        lines = (d["lines"] as? NSNumber)?.intValue ?? 0
    }
}

struct OutlineItem: Equatable {
    let level: Int
    let text: String
}

struct IncomingFile {
    let name: String
    let mimeType: String
    let data: Data
}

protocol EditorViewDelegate: AnyObject {
    func editorDidBecomeReady(_ editor: EditorViewController)
    func editor(_ editor: EditorViewController, didChange markdown: String, stats: TextStats)
    func editorDidBecomeDirty(_ editor: EditorViewController)
    func editor(_ editor: EditorViewController, didUpdateStats stats: TextStats)
    func editor(_ editor: EditorViewController, didUpdateOutline items: [OutlineItem])
    func editor(_ editor: EditorViewController, didRequestOpen link: String)
    func editor(_ editor: EditorViewController, didReceive files: [IncomingFile])
    func editor(_ editor: EditorViewController, didSwitchMode mode: String)
    func editor(_ editor: EditorViewController, didTriggerShortcut name: String)
}

/// WKWebView tuned for a document editor: the menu bar gets first pick of
/// key equivalents, undo goes to the editor's own history, and browser-only
/// context menu items are removed.
final class PlumeWebView: WKWebView {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    /// WebKit registers its own (unused) undo actions here instead of in the
    /// document's undo manager.
    private let undoSink: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()

    override var undoManager: UndoManager? { undoSink }

    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !PlumeWebView.editorOwnsShortcut(event),
           let menu = NSApp.mainMenu {
            if menu.performKeyEquivalent(with: event) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Context-sensitive shortcuts the editor handles itself (table row and
    /// column editing, heading level, heading / mode shortcuts). These go to
    /// the page first; if the page ignores them they still reach the menu.
    static func editorOwnsShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = event.keyCode
        let equal: UInt16 = 24, minus: UInt16 = 27
        if flags == [.command] {
            return code == equal || code == minus
        }
        if flags == [.command, .shift] {
            // F, G, =, -, L, C, R
            return [3, 5, equal, minus, 37, 8, 15].contains(code)
        }
        if flags == [.command, .option] {
            // Digits 1-9 on the main keyboard.
            return [18, 19, 20, 21, 23, 22, 26, 28, 25].contains(code)
        }
        return false
    }

    private static let hiddenMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierStop",
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierShareMenu",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let showInspector = UserDefaults.standard.bool(forKey: "PlumeDebug")
        for item in menu.items.reversed() {
            let id = item.identifier?.rawValue ?? ""
            if PlumeWebView.hiddenMenuItems.contains(id) || (!showInspector && id == "WKMenuItemIdentifierInspectElement") {
                menu.removeItem(item)
            }
        }
        // Tidy up separators left behind.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = true }
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Hosts the web editor and translates between Swift and window.Plume.
final class EditorViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var delegate: EditorViewDelegate?
    private(set) var webView: PlumeWebView!
    private(set) var isReady = false
    private(set) var mode = "ir"
    private var settingsObserver: NSObjectProtocol?

    private var editorURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "editor")
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptMessageHandler(self), name: "plume")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        if #available(macOS 13.3, *) {
            config.preferences.shouldPrintBackgrounds = true
        }
        config.suppressesIncrementalRendering = false

        let webView = PlumeWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.onUndo = { [weak self] in self?.command("undo") }
        webView.onRedo = { [weak self] in self?.command("redo") }
        self.webView = webView
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        loadEditorPage()
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func loadEditorPage() {
        guard let url = editorURL else {
            NSLog("Plume: editor resources are missing from the app bundle")
            return
        }
        isReady = false
        webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: Calling into the page

    /// Runs `return <body>` in the page with the given named arguments.
    func call(_ body: String, _ arguments: [String: Any] = [:], completion: ((Any?) -> Void)? = nil) {
        webView.callAsyncJavaScript("return " + body, arguments: arguments, in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion?(value)
            case .failure(let error):
                NSLog("Plume JS error in \(body): \(error.localizedDescription)")
                completion?(nil)
            }
        }
    }

    private static func baseString(for folder: URL?) -> String {
        let url = folder ?? FileManager.default.homeDirectoryForCurrentUser
        var string = url.absoluteString
        if !string.hasSuffix("/") { string += "/" }
        return string
    }

    func load(markdown: String, baseFolder: URL?) {
        guard isReady else { return }
        call("Plume.load(opts)", ["opts": ["markdown": markdown, "baseURL": EditorViewController.baseString(for: baseFolder)]])
    }

    func reload(markdown: String) {
        guard isReady else { return }
        call("Plume.reload(md)", ["md": markdown])
    }

    func setBaseFolder(_ folder: URL?) {
        guard isReady else { return }
        call("Plume.setBase(url)", ["url": EditorViewController.baseString(for: folder)])
    }

    func command(_ name: String) {
        guard isReady else { return }
        call("Plume.command(name)", ["name": name])
    }

    func insertMarkdown(_ markdown: String) {
        guard isReady else { return }
        call("Plume.insertText(text)", ["text": markdown])
    }

    func insertFiles(_ items: [[String: Any]]) {
        guard isReady, !items.isEmpty else { return }
        call("Plume.insertFiles(items)", ["items": items])
    }

    func toggleSourceMode() {
        guard isReady else { return }
        call("Plume.toggleSourceMode()")
    }

    func scrollToHeading(at index: Int) {
        guard isReady else { return }
        call("Plume.scrollToHeading(i)", ["i": index])
    }

    func focusEditor() {
        guard isReady else { return }
        view.window?.makeFirstResponder(webView)
        call("Plume.focus()")
    }

    func flush(_ completion: @escaping (String?) -> Void) {
        guard isReady else {
            completion(nil)
            return
        }
        var finished = false
        let finish: (String?) -> Void = { text in
            guard !finished else { return }
            finished = true
            completion(text)
        }
        call("Plume.getMarkdown()") { finish($0 as? String) }
        // Never let a stuck page block saving or closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
    }

    func renderForExport(_ completion: @escaping (String?) -> Void) {
        guard isReady else {
            completion(nil)
            return
        }
        call("Plume.renderForExport()") { completion($0 as? String) }
    }

    func selectedText(_ completion: @escaping (String) -> Void) {
        call("Plume.selectedText()") { completion(($0 as? String) ?? "") }
    }

    private func applySettings() {
        guard isReady else { return }
        let settings = Settings.shared
        webView.pageZoom = CGFloat(settings.zoom)
        call("Plume.setFocusMode(on)", ["on": settings.focusMode])
        call("Plume.setTypewriterMode(on)", ["on": settings.typewriterMode])
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            applySettings()
            delegate?.editorDidBecomeReady(self)
        case "dirty":
            delegate?.editorDidBecomeDirty(self)
        case "change":
            if let markdown = body["markdown"] as? String {
                delegate?.editor(self, didChange: markdown, stats: TextStats(body["stats"]))
            }
        case "stats":
            delegate?.editor(self, didUpdateStats: TextStats(body["stats"]))
        case "outline":
            let raw = body["items"] as? [[String: Any]] ?? []
            let items = raw.map {
                OutlineItem(level: ($0["level"] as? NSNumber)?.intValue ?? 1, text: $0["text"] as? String ?? "")
            }
            delegate?.editor(self, didUpdateOutline: items)
        case "openLink":
            if let url = body["url"] as? String {
                delegate?.editor(self, didRequestOpen: url)
            }
        case "saveFiles":
            let raw = body["files"] as? [[String: Any]] ?? []
            let files = raw.compactMap { item -> IncomingFile? in
                guard let b64 = item["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
                return IncomingFile(name: item["name"] as? String ?? "", mimeType: item["type"] as? String ?? "", data: data)
            }
            delegate?.editor(self, didReceive: files)
        case "mode":
            mode = body["mode"] as? String ?? "ir"
            delegate?.editor(self, didSwitchMode: mode)
        case "shortcut":
            if let name = body["name"] as? String {
                delegate?.editor(self, didTriggerShortcut: name)
            }
        default:
            break
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow) // embedded iframes (videos etc.)
            return
        }
        if url.isFileURL, let editorURL, url.standardizedFileURL.path == editorURL.standardizedFileURL.path,
           navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated {
            delegate?.editor(self, didRequestOpen: url.absoluteString)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recover from a crashed web process; the window reloads the document
        // when the page reports it is ready again.
        loadEditorPage()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            delegate?.editor(self, didRequestOpen: url.absoluteString)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
