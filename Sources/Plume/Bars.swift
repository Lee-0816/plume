import AppKit

/// Plain view filled with the editor background colour (tracks dark mode).
class EditorBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        layer?.backgroundColor = Palette.editorBackground.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Status bar

/// Thin bar under the editor: sidebar / source-mode toggles and word count.
final class StatusBarView: EditorBackgroundView {
    var onToggleSidebar: (() -> Void)?
    var onToggleSource: (() -> Void)?

    private let sidebarButton = StatusBarView.iconButton("sidebar.left", tip: "显示/隐藏侧边栏 (⌃⌘S)")
    private let sourceButton = StatusBarView.iconButton("chevron.left.forwardslash.chevron.right", tip: "源代码模式 (⌘/)")
    private let modeLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        sourceButton.target = self
        sourceButton.action = #selector(sourceClicked)

        for label in [modeLabel, statsLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        statsLabel.alignment = .right

        for v in [sidebarButton, sourceButton, modeLabel, statsLabel] as [NSView] {
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sourceButton.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 6),
            sourceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeLabel.leadingAnchor.constraint(equalTo: sourceButton.trailingAnchor, constant: 8),
            modeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modeLabel.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func iconButton(_ symbol: String, tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    func update(stats: TextStats) {
        statsLabel.stringValue = "\(stats.words) 字"
        statsLabel.toolTip = "字数 \(stats.words)  ·  字符 \(stats.chars)  ·  行数 \(stats.lines)"
    }

    func update(mode: String) {
        let source = mode == "sv"
        modeLabel.stringValue = source ? "源代码模式" : ""
        sourceButton.contentTintColor = source ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func sidebarClicked() { onToggleSidebar?() }
    @objc private func sourceClicked() { onToggleSource?() }
}

// MARK: - Find bar

protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBarView, search query: String, backwards: Bool, incremental: Bool)
    func findBar(_ bar: FindBarView, replace query: String, with replacement: String)
    func findBar(_ bar: FindBarView, replaceAll query: String, with replacement: String)
    func findBarDidClose(_ bar: FindBarView)
}

final class FindBarView: EditorBackgroundView, NSSearchFieldDelegate, NSTextFieldDelegate {
    weak var delegate: FindBarDelegate?

    let searchField = NSSearchField()
    let replaceField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl()
    private let caseCheckbox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)
    private let replaceButton = NSButton(title: "替换", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "全部替换", target: nil, action: nil)
    private let replaceRow = NSStackView()
    private let separator = NSBox()

    var caseSensitive: Bool { caseCheckbox.state == .on }
    var query: String { searchField.stringValue }

    var showsReplace: Bool = false {
        didSet { replaceRow.isHidden = !showsReplace }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        searchField.placeholderString = "查找"
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted(_:))

        replaceField.placeholderString = "替换为"
        replaceField.delegate = self
        replaceField.target = self
        replaceField.action = #selector(replaceSubmitted(_:))

        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一个"), forSegment: 0)
        navigation.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下一个"), forSegment: 1)
        navigation.setToolTip("查找上一个 (⇧⌘G)", forSegment: 0)
        navigation.setToolTip("查找下一个 (⌘G)", forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate(_:))

        caseCheckbox.target = self
        caseCheckbox.action = #selector(optionsChanged(_:))
        caseCheckbox.controlSize = .small
        caseCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        doneButton.target = self
        doneButton.action = #selector(close(_:))
        doneButton.bezelStyle = .rounded
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked(_:))
        replaceButton.bezelStyle = .rounded
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked(_:))
        replaceAllButton.bezelStyle = .rounded

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let findRow = NSStackView(views: [searchField, countLabel, navigation, caseCheckbox, doneButton])
        findRow.spacing = 8
        findRow.orientation = .horizontal
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        replaceRow.setViews([replaceField, replaceButton, replaceAllButton], in: .leading)
        replaceRow.spacing = 8
        replaceRow.orientation = .horizontal
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceRow.isHidden = true

        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Palette.hairline
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            findRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            replaceRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setMatchCount(_ count: Int?) {
        guard let count, !query.isEmpty else {
            countLabel.stringValue = ""
            return
        }
        countLabel.stringValue = count == 0 ? "无结果" : "\(count) 个结果"
        countLabel.textColor = count == 0 ? .systemRed : .secondaryLabelColor
    }

    func focusSearch(selectAll: Bool = true) {
        window?.makeFirstResponder(searchField)
        if selectAll { searchField.currentEditor()?.selectAll(nil) }
    }

    // MARK: Actions

    @objc private func searchSubmitted(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        delegate?.findBar(self, search: query, backwards: shift, incremental: false)
    }

    @objc private func replaceSubmitted(_ sender: Any?) {
        delegate?.findBar(self, replace: query, with: replaceField.stringValue)
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        delegate?.findBar(self, search: query, backwards: sender.selectedSegment == 0, incremental: false)
    }

    @objc private func optionsChanged(_ sender: Any?) {
        delegate?.findBar(self, search: query, backwards: false, incremental: true)
    }

    @objc private func replaceClicked(_ sender: Any?) {
        delegate?.findBar(self, replace: query, with: replaceField.stringValue)
    }

    @objc private func replaceAllClicked(_ sender: Any?) {
        delegate?.findBar(self, replaceAll: query, with: replaceField.stringValue)
    }

    @objc func close(_ sender: Any?) {
        delegate?.findBarDidClose(self)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        delegate?.findBar(self, search: query, backwards: false, incremental: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close(nil)
            return true
        }
        return false
    }
}
