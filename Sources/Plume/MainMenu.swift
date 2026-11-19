import AppKit

/// Builds the menu bar. Shortcuts follow common Markdown-editor conventions.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(paragraphMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    // MARK: Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0,
                            command: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.representedObject = command
        item.target = target
        menu.addItem(item)
        return item
    }

    private static func format(_ menu: NSMenu, _ title: String, _ command: String, _ key: String = "",
                               _ modifiers: NSEvent.ModifierFlags = [.command]) {
        add(menu, title, #selector(EditorWindowController.formatCommand(_:)), key, modifiers, command: command)
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Plume")
        add(menu, "关于 Plume", #selector(AppDelegate.showAbout(_:)))
        menu.addItem(.separator())
        let services = NSMenu(title: "服务")
        let servicesItem = add(menu, "服务", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        add(menu, "隐藏 Plume", #selector(NSApplication.hide(_:)), "h")
        add(menu, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "全部显示", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "退出 Plume", #selector(AppDelegate.quitAfterFlushing(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "文件")
        add(menu, "新建", #selector(NSDocumentController.newDocument(_:)), "n")
        add(menu, "打开…", #selector(NSDocumentController.openDocument(_:)), "o")
        add(menu, "打开文件夹…", #selector(AppDelegate.openFolder(_:)), "o", [.command, .shift])

        let recent = NSMenu(title: "打开最近使用")
        add(recent, "清除菜单", #selector(NSDocumentController.clearRecentDocuments(_:)))
        let recentItem = add(menu, "打开最近使用", nil)
        recentItem.submenu = recent

        menu.addItem(.separator())
        add(menu, "关闭", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "存储…", #selector(NSDocument.save(_:)), "s")
        add(menu, "复制", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
        add(menu, "重新命名…", #selector(NSDocument.rename(_:)))
        add(menu, "移动到…", #selector(NSDocument.move(_:)))
        add(menu, "恢复到上次存储的版本", #selector(NSDocument.revertToSaved(_:)))
        menu.addItem(.separator())
        add(menu, "在 Finder 中显示", #selector(EditorWindowController.revealInFinder(_:)), "r", [.command, .option])
        menu.addItem(.separator())

        let export = NSMenu(title: "导出")
        add(export, "PDF…", #selector(NSDocument.saveToPDF(_:)), "e", [.command, .option])
        add(export, "HTML…", #selector(EditorWindowController.exportHTML(_:)))
        let exportItem = add(menu, "导出", nil)
        exportItem.submenu = export

        menu.addItem(.separator())
        add(menu, "页面设置…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
        add(menu, "打印…", #selector(NSDocument.printDocument(_:)), "p")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        add(menu, "撤销", #selector(PlumeWebView.undo(_:)), "z")
        add(menu, "重做", #selector(PlumeWebView.redo(_:)), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "剪切", #selector(NSText.cut(_:)), "x")
        add(menu, "拷贝", #selector(NSText.copy(_:)), "c")
        add(menu, "粘贴", #selector(NSText.paste(_:)), "v")
        add(menu, "粘贴为纯文本", #selector(EditorWindowController.plumePasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(menu, "删除", #selector(NSText.delete(_:)))
        add(menu, "全选", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "查找")
        let findAction = #selector(EditorWindowController.plumeFind(_:))
        add(find, "查找…", findAction, "f", tag: 1)
        add(find, "查找并替换…", findAction, "f", [.command, .option], tag: 2)
        add(find, "查找下一个", findAction, "g", tag: 3)
        add(find, "查找上一个", findAction, "g", [.command, .shift], tag: 4)
        add(find, "使用所选内容查找", findAction, "e", tag: 5)
        let findItem = add(menu, "查找", nil)
        findItem.submenu = find

        menu.addItem(.separator())
        add(menu, "表情与符号", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control])
        return menu
    }

    private static func paragraphMenu() -> NSMenu {
        let menu = NSMenu(title: "段落")
        for level in 1...6 {
            let names = ["一", "二", "三", "四", "五", "六"]
            format(menu, "\(names[level - 1])级标题", "heading-\(level)", "\(level)")
        }
        format(menu, "段落", "heading-0", "0")
        menu.addItem(.separator())
        format(menu, "提升标题级别", "heading-up", "=")
        format(menu, "降低标题级别", "heading-down", "-")
        menu.addItem(.separator())
        format(menu, "表格", "table", "t", [.command, .option])
        format(menu, "代码块", "code", "c", [.command, .option])
        format(menu, "公式块", "math-block", "b", [.command, .option])
        format(menu, "引用", "quote", "q", [.command, .option])
        menu.addItem(.separator())
        format(menu, "有序列表", "ordered-list", "o", [.command, .option])
        format(menu, "无序列表", "list", "u", [.command, .option])
        format(menu, "任务列表", "check", "x", [.command, .option])
        format(menu, "增加缩进", "indent", "]")
        format(menu, "减少缩进", "outdent", "[")
        menu.addItem(.separator())
        format(menu, "水平分割线", "line", "-", [.command, .option])
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "格式")
        format(menu, "加粗", "bold", "b")
        format(menu, "斜体", "italic", "i")
        format(menu, "删除线", "strike", "~", [.control, .shift])
        format(menu, "高亮", "highlight", "h", [.command, .shift])
        format(menu, "行内代码", "inline-code", "`", [.control])
        menu.addItem(.separator())
        format(menu, "超链接", "link", "k")
        add(menu, "图片…", #selector(EditorWindowController.insertImage(_:)), "i", [.command, .control])
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "显示")
        add(menu, "源代码模式", #selector(EditorWindowController.toggleSourceMode(_:)), "/")
        menu.addItem(.separator())
        add(menu, "隐藏侧边栏", #selector(EditorWindowController.toggleSidebarPane(_:)), "s", [.command, .control])
        add(menu, "大纲", #selector(EditorWindowController.showOutline(_:)), "1", [.command, .control])
        add(menu, "文件树", #selector(EditorWindowController.showFileTree(_:)), "3", [.command, .control])
        menu.addItem(.separator())
        add(menu, "专注模式", #selector(EditorWindowController.toggleFocusMode(_:)), functionKey(NSF8FunctionKey), [])
        add(menu, "打字机模式", #selector(EditorWindowController.toggleTypewriterMode(_:)), functionKey(NSF9FunctionKey), [])
        menu.addItem(.separator())

        let appearance = NSMenu(title: "外观")
        add(appearance, "跟随系统", #selector(AppDelegate.setAppearanceMode(_:)), tag: 0)
        add(appearance, "浅色", #selector(AppDelegate.setAppearanceMode(_:)), tag: 1)
        add(appearance, "深色", #selector(AppDelegate.setAppearanceMode(_:)), tag: 2)
        let appearanceItem = add(menu, "外观", nil)
        appearanceItem.submenu = appearance
        menu.addItem(.separator())

        add(menu, "实际大小", #selector(EditorWindowController.actualSizeText(_:)), "0", [.command, .control])
        add(menu, "放大", #selector(EditorWindowController.zoomInText(_:)), "=", [.command, .control])
        add(menu, "缩小", #selector(EditorWindowController.zoomOutText(_:)), "-", [.command, .control])
        menu.addItem(.separator())
        add(menu, "进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "窗口")
        add(menu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "缩放", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "帮助")
        add(menu, "Markdown 参考", #selector(AppDelegate.openMarkdownReference(_:)))
        return menu
    }
}
