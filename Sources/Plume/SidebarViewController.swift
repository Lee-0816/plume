import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectFile url: URL)
    func sidebar(_ sidebar: SidebarViewController, didSelectHeadingAt index: Int)
    func sidebarRequestsOpenFolder(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, didRename url: URL, to newURL: URL)
}

private final class SidebarCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private(set) var leadingConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        super.init(frame: .zero)
        let anchorView: NSView = showsIcon ? icon : label
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        textField = label
        addSubview(label)
        if showsIcon {
            imageView = icon
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            ])
        }
        let lead = anchorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            lead,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        leadingConstraint = lead
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Sidebar with two panes: the folder's Markdown files and the document outline.
final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate {

    enum Tab: Int { case files = 0, outline = 1 }

    weak var delegate: SidebarDelegate?

    private let segmented = NSSegmentedControl(labels: ["文件", "大纲"], trackingMode: .selectOne, target: nil, action: nil)
    private let folderIcon = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let fileOutline = NSOutlineView()
    private let fileScroll = NSScrollView()
    private let headingTable = NSTableView()
    private let headingScroll = NSScrollView()
    private let emptyFiles = NSStackView()
    private let emptyOutline = NSTextField(labelWithString: "文档中还没有标题")

    private var rootNode: FileNode?
    private(set) var rootURL: URL?
    private var currentFile: URL?
    private var watcher: FolderWatcher?
    private var reloadPending = false
    private var suppressSelection = false
    private var headings: [OutlineItem] = []
    private var minHeadingLevel = 1
    private var renamingNode: FileNode?

    var tab: Tab = .files {
        didSet { updateTab() }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        view = root

        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.segmentDistribution = .fillEqually
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false

        folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderIcon.contentTintColor = .secondaryLabelColor
        folderIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.translatesAutoresizingMaskIntoConstraints = false

        configureFileOutline()
        configureHeadingTable()
        configureEmptyStates()

        for v in [segmented, folderIcon, folderLabel, fileScroll, headingScroll, emptyFiles, emptyOutline] as [NSView] {
            root.addSubview(v)
        }

        let guide = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            folderIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            folderIcon.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            folderLabel.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            folderLabel.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 5),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            fileScroll.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 4),
            fileScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            headingScroll.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            headingScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headingScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headingScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyFiles.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyFiles.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyFiles.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),

            emptyOutline.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyOutline.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        tab = Tab(rawValue: Settings.shared.sidebarTab) ?? .files
        updateTab()
    }

    private func configureFileOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        fileOutline.addTableColumn(column)
        fileOutline.outlineTableColumn = column
        fileOutline.headerView = nil
        fileOutline.style = .sourceList
        fileOutline.rowSizeStyle = .default
        fileOutline.floatsGroupRows = false
        fileOutline.indentationPerLevel = 12
        fileOutline.autoresizesOutlineColumn = false
        fileOutline.dataSource = self
        fileOutline.delegate = self
        fileOutline.target = self
        fileOutline.action = #selector(fileRowClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        fileOutline.menu = menu

        fileScroll.documentView = fileOutline
        fileScroll.hasVerticalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.drawsBackground = false
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureHeadingTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        headingTable.addTableColumn(column)
        headingTable.headerView = nil
        headingTable.style = .sourceList
        headingTable.rowSizeStyle = .default
        headingTable.dataSource = self
        headingTable.delegate = self
        headingTable.target = self
        headingTable.action = #selector(headingClicked(_:))

        headingScroll.documentView = headingTable
        headingScroll.hasVerticalScroller = true
        headingScroll.autohidesScrollers = true
        headingScroll.drawsBackground = false
        headingScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureEmptyStates() {
        let label = NSTextField(labelWithString: "尚未打开文件夹")
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: "打开文件夹…", target: self, action: #selector(openFolderClicked(_:)))
        button.bezelStyle = .rounded
        emptyFiles.orientation = .vertical
        emptyFiles.spacing = 10
        emptyFiles.addArrangedSubview(label)
        emptyFiles.addArrangedSubview(button)
        emptyFiles.translatesAutoresizingMaskIntoConstraints = false

        emptyOutline.textColor = .secondaryLabelColor
        emptyOutline.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateTab() {
        guard isViewLoaded else { return }
        segmented.selectedSegment = tab.rawValue
        let files = tab == .files
        let hasRoot = rootURL != nil
        fileScroll.isHidden = !files || !hasRoot
        folderIcon.isHidden = !files || !hasRoot
        folderLabel.isHidden = !files || !hasRoot
        emptyFiles.isHidden = !files || hasRoot
        headingScroll.isHidden = files
        emptyOutline.isHidden = files || !headings.isEmpty
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        tab = Tab(rawValue: sender.selectedSegment) ?? .files
        Settings.shared.sidebarTab = tab.rawValue
    }

    @objc private func openFolderClicked(_ sender: Any?) {
        delegate?.sidebarRequestsOpenFolder(self)
    }

    // MARK: Folder

    func setRoot(_ url: URL?) {
        let standardized = url?.standardizedFileURL
        guard standardized != rootURL else { return }
        rootURL = standardized
        watcher?.stop()
        watcher = nil
        if let standardized {
            folderLabel.stringValue = standardized.lastPathComponent
            folderLabel.toolTip = standardized.path
            watcher = FolderWatcher(url: standardized) { [weak self] in self?.scheduleReload() }
        }
        reloadTree(keepExpansion: false)
        updateTab()
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false
            self?.reloadTree(keepExpansion: true)
        }
    }

    func reloadTree(keepExpansion: Bool) {
        guard isViewLoaded, renamingNode == nil else { return }
        let expanded = keepExpansion ? expandedURLs() : []
        rootNode = rootURL.map { FileNode(url: $0, isDirectory: true) }
        fileOutline.reloadData()
        if let rootNode {
            restoreExpansion(rootNode, expanded)
        }
        highlight(currentFile)
    }

    private func expandedURLs() -> Set<URL> {
        var result = Set<URL>()
        for row in 0..<fileOutline.numberOfRows {
            if let node = fileOutline.item(atRow: row) as? FileNode, node.isDirectory, fileOutline.isItemExpanded(node) {
                result.insert(node.url)
            }
        }
        return result
    }

    private func restoreExpansion(_ node: FileNode, _ expanded: Set<URL>) {
        for child in node.children where child.isDirectory && expanded.contains(child.url) {
            fileOutline.expandItem(child)
            restoreExpansion(child, expanded)
        }
    }

    /// Select the row for the given file, expanding its parent folders.
    func highlight(_ url: URL?) {
        currentFile = url?.standardizedFileURL
        guard isViewLoaded else { return }
        suppressSelection = true
        defer { suppressSelection = false }
        guard let target = currentFile, let rootNode,
              target.path.hasPrefix(rootNode.url.path + "/") else {
            fileOutline.deselectAll(nil)
            return
        }
        var node = rootNode
        let components = target.pathComponents.dropFirst(rootNode.url.pathComponents.count)
        for component in components {
            guard let next = node.children.first(where: { $0.name == component }) else { break }
            if next.isDirectory { fileOutline.expandItem(next) }
            node = next
        }
        let row = fileOutline.row(forItem: node)
        if node.url == target, row >= 0 {
            fileOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            fileOutline.scrollRowToVisible(row)
        } else {
            fileOutline.deselectAll(nil)
        }
    }

    // MARK: NSOutlineView (files)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? rootNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? rootNode)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? SidebarCellView)
            ?? SidebarCellView(identifier: id, showsIcon: true)
        cell.label.stringValue = node.name
        cell.label.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.label.isEditable = false
        cell.label.delegate = self
        cell.icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        cell.toolTip = node.url.path
        return cell
    }

    @objc private func fileRowClicked(_ sender: Any?) {
        let row = fileOutline.clickedRow
        guard row >= 0, let node = fileOutline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if fileOutline.isItemExpanded(node) {
                fileOutline.collapseItem(node)
            } else {
                fileOutline.expandItem(node)
            }
            highlight(currentFile)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = fileOutline.selectedRow
        guard row >= 0, let node = fileOutline.item(atRow: row) as? FileNode, !node.isDirectory else { return }
        if node.url != currentFile {
            delegate?.sidebar(self, didSelectFile: node.url)
        }
    }

    // MARK: Context menu

    private var menuNode: FileNode? {
        let row = fileOutline.clickedRow
        return row >= 0 ? fileOutline.item(atRow: row) as? FileNode : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rootURL != nil else { return }
        let node = menuNode
        menu.addItem(withTitle: "新建 Markdown 文件", action: #selector(newFile(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "新建文件夹", action: #selector(newFolder(_:)), keyEquivalent: "").target = self
        if node != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "重命名…", action: #selector(renameItem(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "移到废纸篓", action: #selector(moveToTrash(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新", action: #selector(refresh(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开其他文件夹…", action: #selector(openFolderClicked(_:)), keyEquivalent: "").target = self
    }

    private func targetFolder(for node: FileNode?) -> URL? {
        guard let node else { return rootURL }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func uniqueURL(in folder: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let url = ext.map { folder.appendingPathComponent(name).appendingPathExtension($0) } ?? folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    @objc private func newFile(_ sender: Any?) {
        guard let folder = targetFolder(for: menuNode) else { return }
        let url = uniqueURL(in: folder, base: "未命名", ext: "md")
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            reloadTree(keepExpansion: true)
            delegate?.sidebar(self, didSelectFile: url)
        } catch {
            presentError(error)
        }
    }

    @objc private func newFolder(_ sender: Any?) {
        guard let folder = targetFolder(for: menuNode) else { return }
        let url = uniqueURL(in: folder, base: "新建文件夹", ext: nil)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            reloadTree(keepExpansion: true)
            if let node = findNode(url) {
                beginRename(node)
            }
        } catch {
            presentError(error)
        }
    }

    private func findNode(_ url: URL) -> FileNode? {
        guard let rootNode else { return nil }
        let target = url.standardizedFileURL
        var node = rootNode
        for component in target.pathComponents.dropFirst(rootNode.url.pathComponents.count) {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            if next.isDirectory, next.url != target { fileOutline.expandItem(next) }
            node = next
        }
        return node.url == target ? node : nil
    }

    @objc private func renameItem(_ sender: Any?) {
        guard let node = menuNode else { return }
        beginRename(node)
    }

    private func beginRename(_ node: FileNode) {
        let row = fileOutline.row(forItem: node)
        guard row >= 0, let cell = fileOutline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { return }
        renamingNode = node
        cell.label.isEditable = true
        cell.label.isSelectable = true
        view.window?.makeFirstResponder(cell.label)
        if let editor = cell.label.currentEditor() {
            let name = node.name as NSString
            let stemLength = node.isDirectory ? name.length : (name.deletingPathExtension as NSString).length
            editor.selectedRange = NSRange(location: 0, length: stemLength)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let node = renamingNode else { return }
        renamingNode = nil
        field.isEditable = false
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != node.name, !newName.contains("/") else {
            field.stringValue = node.name
            return
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: node.url, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { source, target in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            do {
                coordinator.item(at: source, willMoveTo: target)
                try FileManager.default.moveItem(at: source, to: target)
                coordinator.item(at: source, didMoveTo: target)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError {
            field.stringValue = node.name
            presentError(error)
            return
        }
        delegate?.sidebar(self, didRename: node.url, to: destination)
        reloadTree(keepExpansion: true)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let node = menuNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func moveToTrash(_ sender: Any?) {
        guard let node = menuNode else { return }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            if let error { self?.presentError(error) }
            self?.reloadTree(keepExpansion: true)
        }
    }

    @objc private func refresh(_ sender: Any?) {
        reloadTree(keepExpansion: true)
    }

    // MARK: Outline (headings)

    func setOutline(_ items: [OutlineItem]) {
        guard items != headings else { return }
        headings = items
        minHeadingLevel = items.map(\.level).min() ?? 1
        if isViewLoaded {
            headingTable.reloadData()
            updateTab()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        headings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarCellView)
            ?? SidebarCellView(identifier: id, showsIcon: false)
        let item = headings[row]
        let depth = max(0, item.level - minHeadingLevel)
        cell.leadingConstraint.constant = 6 + CGFloat(depth) * 14
        cell.label.stringValue = item.text.isEmpty ? "（空标题）" : item.text
        cell.label.font = depth == 0
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .systemFont(ofSize: NSFont.systemFontSize)
        cell.label.textColor = depth >= 2 ? .secondaryLabelColor : .labelColor
        cell.toolTip = item.text
        return cell
    }

    @objc private func headingClicked(_ sender: Any?) {
        let row = headingTable.clickedRow
        guard row >= 0 else { return }
        delegate?.sidebar(self, didSelectHeadingAt: row)
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}
