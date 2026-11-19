import AppKit

/// A Markdown file. The editor web view owns the live text; this class keeps
/// a copy that is refreshed from the editor shortly after every edit and is
/// flushed explicitly before user-initiated saves and closes.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    static let markdownType = "net.daringfireball.markdown"
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "text", "txt"]

    private(set) var markdown = ""

    /// Folder the sidebar should show when this document gets its first window.
    var preferredRootFolder: URL?

    override init() {
        super.init()
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    var editorWindowController: EditorWindowController? {
        windowControllers.lazy.compactMap { $0 as? EditorWindowController }.first
    }

    // MARK: Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        markdown = MarkdownDocument.decode(data)
        editorWindowController?.documentDidReload()
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(markdown.utf8)
    }

    /// Used for "Markdown Reference" and similar generated documents.
    func setInitialContent(_ text: String) {
        markdown = text
    }

    static func decode(_ raw: Data) -> String {
        var data = raw
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        if let text = String(data: data, encoding: .utf8) {
            return normalizeNewlines(text)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return normalizeNewlines(text)
        }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return normalizeNewlines(text)
        }
        return normalizeNewlines(String(decoding: data, as: UTF8.self))
    }

    private static func normalizeNewlines(_ text: String) -> String {
        (text as NSString)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Editor synchronisation

    func editorDidChange(_ text: String) {
        guard text != markdown else { return }
        markdown = text
        updateChangeCount(.changeDone)
    }

    func editorDidBecomeDirty() {
        if !isDocumentEdited {
            updateChangeCount(.changeDone)
        }
    }

    /// Pull the latest Markdown out of the editor, then continue.
    func flushEditor(_ then: @escaping () -> Void) {
        guard let editor = editorWindowController?.editor else {
            then()
            return
        }
        editor.flush { [weak self] text in
            if let text, let self {
                self.editorDidChange(text)
            }
            then()
        }
    }

    override func save(_ sender: Any?) {
        flushEditor { super.save(sender) }
    }

    override func saveAs(_ sender: Any?) {
        flushEditor { super.saveAs(sender) }
    }

    override func duplicate(_ sender: Any?) {
        flushEditor { super.duplicate(sender) }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        flushEditor {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    override var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            DispatchQueue.main.async { [weak self] in
                self?.editorWindowController?.documentLocationDidChange()
            }
        }
    }

    // MARK: External changes

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            self?.reloadIfChangedOnDisk()
        }
    }

    private func reloadIfChangedOnDisk() {
        guard let url = fileURL, let type = fileType, !isDocumentEdited else { return }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let diskDate = values.contentModificationDate else { return }
        if let known = fileModificationDate, diskDate <= known { return }
        guard let data = try? Data(contentsOf: url) else { return }
        if MarkdownDocument.decode(data) == markdown {
            fileModificationDate = diskDate
            return
        }
        try? revert(toContentsOf: url, ofType: type)
    }

    // MARK: Printing and PDF export

    override func printDocument(_ sender: Any?) {
        prepareForPrinting { super.printDocument(sender) }
    }

    override func saveToPDF(_ sender: Any?) {
        prepareForPrinting { super.saveToPDF(sender) }
    }

    private func prepareForPrinting(_ then: @escaping () -> Void) {
        guard let editor = editorWindowController?.editor else {
            then()
            return
        }
        editor.renderForExport { _ in then() }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let webView = editorWindowController?.editor.webView else {
            throw CocoaError(.featureUnsupported)
        }
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 40
        info.bottomMargin = 40
        info.leftMargin = 40
        info.rightMargin = 40
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        // WebKit renders printed pages asynchronously and expects the
        // operation to run off the main thread; otherwise pages come out blank.
        operation.canSpawnSeparateThread = true
        operation.jobTitle = displayName
        return operation
    }
}
