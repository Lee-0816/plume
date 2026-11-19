# Plume

一个 macOS 原生的所见即所得 Markdown 编辑器，体验类似 Typora：输入 Markdown 语法立即渲染，光标移进某个元素时显示它的源码标记。

- 原生外壳：Swift + AppKit（`NSDocument` 文档体系、菜单、侧边栏、查找栏、打印）
- 编辑内核：内嵌 WKWebView，运行 [Vditor](https://github.com/Vanessa219/vditor)（MIT）的「即时渲染」模式，全部资源打包在 App 内，离线可用
- 系统要求：macOS 13 及以上

## 功能

| 类别 | 内容 |
| --- | --- |
| 编辑 | 即时渲染（类 Typora）/ 源代码模式（⌘/）切换；GFM 表格、任务列表、脚注、`==高亮==`、`[toc]` |
| 渲染 | 代码高亮、KaTeX 公式、Mermaid / 流程图 / Graphviz / ECharts / 五线谱等图表 |
| 文档 | 打开/新建/保存/另存/重命名/移动、自动保存与版本历史（文件 → 恢复到）、最近打开、多窗口与原生标签页、外部修改自动重载 |
| 侧边栏 | 文件树（打开文件夹，⇧⌘O；新建/重命名/移到废纸篓）与大纲（点击跳转） |
| 图片 | 粘贴或拖入图片自动存到文档旁的 `assets/` 并插入相对路径；未保存的文档存到 `~/Library/Application Support/Plume/Images` |
| 查找 | 查找（⌘F）、查找并替换（⌥⌘F）、下一个/上一个（⌘G / ⇧⌘G）、全部替换 |
| 显示 | 跟随系统 / 浅色 / 深色；专注模式（F8）、打字机模式（F9）；文字缩放 |
| 导出 | PDF（分页，始终使用浅色排版）、HTML（独立文件）、打印 |

## 快捷键

| 功能 | 快捷键 | 功能 | 快捷键 |
| --- | --- | --- | --- |
| 一至六级标题 | ⌘1 … ⌘6 | 段落 | ⌘0 |
| 提升/降低标题级别 | ⌘= / ⌘- | 加粗 / 斜体 | ⌘B / ⌘I |
| 行内代码 | ⌃\` | 删除线 | ⌃⇧\` |
| 高亮 | ⇧⌘H | 超链接 | ⌘K |
| 插入图片 | ⌃⌘I | 表格 | ⌥⌘T |
| 代码块 | ⌥⌘C | 公式块 | ⌥⌘B |
| 引用 | ⌥⌘Q | 有序 / 无序 / 任务列表 | ⌥⌘O / ⌥⌘U / ⌥⌘X |
| 缩进 / 取消缩进 | ⌘] / ⌘[ | 分割线 | ⌥⌘- |
| 源代码模式 | ⌘/ | 显示/隐藏侧边栏 | ⌃⌘S |
| 大纲 / 文件树 | ⌃⌘1 / ⌃⌘3 | 放大 / 缩小 / 实际大小 | ⌃⌘= / ⌃⌘- / ⌃⌘0 |
| 导出 PDF | ⌥⌘E | 粘贴为纯文本 | ⌥⇧⌘V |

在表格里，⌘= / ⌘- / ⇧⌘= / ⇧⌘- 等会交给编辑器处理（增删行列、对齐）。按住 ⌘ 点击链接可打开它；指向 `.md` 文件的相对链接会在当前窗口打开。

## 构建

需要 Xcode（或 Command Line Tools，含 Swift 5.9+）和 Node.js（仅首次构建时用 npm 下载 Vditor）。

```bash
scripts/build.sh              # 生成 build/Plume.app（本机架构）
scripts/build.sh --universal  # 同时包含 arm64 与 x86_64
```

安装：把 `build/Plume.app` 拖到「应用程序」文件夹即可。App 使用本地临时签名（ad hoc），在本机构建的副本可以直接打开；如果拷到别的 Mac 上，首次需要右键 →「打开」。

## 项目结构

```
Plume/
├── Package.swift
├── Sources/Plume/
│   ├── main.swift / AppDelegate.swift   启动、全局操作（关于、退出前同步、打开文件夹、外观）
│   ├── MainMenu.swift                   菜单栏与快捷键
│   ├── MarkdownDocument.swift           NSDocument：读写、编码识别、外部修改重载、打印/PDF
│   ├── EditorWindowController.swift     窗口布局、文档切换、图片保存、查找、导出
│   ├── EditorViewController.swift       WKWebView 宿主与 JS 桥（菜单优先的快捷键处理）
│   ├── SidebarViewController.swift      文件树 + 大纲
│   ├── FileTree.swift                   文件节点与 FSEvents 目录监听
│   ├── Bars.swift                       状态栏与查找栏
│   ├── HTMLExporter.swift / Settings.swift
│   └── DebugAutomation.swift            开发用自动化钩子（仅在带 -PlumeAutomation 参数启动时生效）
├── web/src/                             编辑器页面：index.html、app.js（桥接）、theme.css（排版主题）
├── Resources/                           Info.plist、内置的 Markdown 参考文档
└── scripts/                             build.sh、assemble-editor.sh、make-icon.swift
```

### 原生 ↔ 编辑器通信

- Swift → JS：`callAsyncJavaScript` 调用 `window.Plume.*`（`load`、`command`、`setMode`、`renderForExport`…）
- JS → Swift：`webkit.messageHandlers.plume.postMessage({type, …})`，消息类型有 `ready`、`dirty`、`change`、`outline`、`saveFiles`、`openLink` 等
- 每次编辑后约 150ms 把 Markdown 同步到原生文档；⌘S、关闭和 ⌘Q 前还会再取一次最新内容，所以不会丢最后几个字

### 开发调试

```bash
defaults write app.plume.markdown PlumeDebug -bool YES   # 右键菜单显示「检查元素」
```

`DebugAutomation.swift` 提供脚本化冒烟测试，例如：

```bash
build/Plume.app/Contents/MacOS/Plume -PlumeAutomation "open:/path/a.md ;; menukey:cmd+/ ;; js:Plume.info().mode ;; snap:/tmp/a.png ;; quit"
```

## 许可

编辑内核 Vditor 及其附带的第三方库遵循各自的许可证（见 `Plume.app/Contents/Resources/editor/vditor/LICENSE`）。
