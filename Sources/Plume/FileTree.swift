import AppKit
import CoreServices

/// A file or folder in the sidebar tree. Children load lazily.
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private var cachedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    var children: [FileNode] {
        if let cachedChildren { return cachedChildren }
        let loaded = isDirectory ? FileNode.load(url) : []
        cachedChildren = loaded
        return loaded
    }

    private static let skippedFolders: Set<String> = ["node_modules", ".git", "__pycache__"]

    static func load(_ folder: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let nodes: [FileNode] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if isDirectory {
                return skippedFolders.contains(url.lastPathComponent) ? nil : FileNode(url: url, isDirectory: true)
            }
            guard MarkdownDocument.markdownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return FileNode(url: url, isDirectory: false)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Watches a folder tree with FSEvents and calls back (coalesced) on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
