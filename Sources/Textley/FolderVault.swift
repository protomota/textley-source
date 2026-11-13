import AppKit
import CoreServices
import Observation
import UniformTypeIdentifiers

struct FolderEntry: Identifiable, Equatable {
    let url: URL
    let children: [FolderEntry]?
    let modified: Date?
    let size: Int?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isFolder: Bool { children != nil }
    var isImage: Bool { Self.isImage(url) }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func list(_ root: URL) -> [FolderEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
                                         .contentModificationDateKey, .fileSizeKey]
        var remaining = 20_000

        func entries(_ url: URL) -> [FolderEntry] {
            guard remaining > 0,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
                  ) else { return [] }
            let ordered = children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var directories: [FolderEntry] = []
            var files: [FolderEntry] = []
            for child in ordered {
                guard remaining > 0 else { break }
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true, values.isPackage != true else { continue }
                remaining -= 1
                if values.isDirectory == true {
                    directories.append(FolderEntry(url: child, children: entries(child), modified: nil, size: nil))
                } else if values.isRegularFile == true, supportedFile(child) {
                    files.append(FolderEntry(url: child, children: nil,
                                             modified: values.contentModificationDate, size: values.fileSize))
                }
            }
            return directories + files
        }

        return entries(root)
    }

    private static func supportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if ext.isEmpty || isImage(url) { return true }
        if UTType(filenameExtension: ext)?.conforms(to: .text) == true { return true }
        return ["log", "conf", "cfg", "ini", "toml", "yaml", "yml", "jsonl", "env", "lock", "svg", "mdx"].contains(ext.lowercased())
    }
}

@MainActor @Observable
final class FolderVault: Identifiable {
    let url: URL
    nonisolated var id: URL { url }
    private(set) var entries: [FolderEntry] = []
    private(set) var isAvailable = true
    var isExpanded = true

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private let onChange: (URL) -> Void

    init(url: URL, onChange: @escaping (URL) -> Void) {
        self.url = url
        self.onChange = onChange
        // Watching the parent keeps the vault observable if its root is removed and recreated.
        watcher = DirectoryWatcher(root: url, action: { [weak self] in
            Task { @MainActor in self?.refresh(fromEvent: true) }
        })
        refresh(fromEvent: false, initial: true)
        // Some volumes omit FSEvents. Compare a scoped snapshot on those volumes too.
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self != nil else { return }
                if self?.refreshTask == nil { self?.refresh(fromEvent: false) }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        fallbackTask?.cancel()
        watcher = nil
    }

    private func refresh(fromEvent: Bool, initial: Bool = false) {
        refreshTask?.cancel()
        let url = self.url
        refreshTask = Task { [weak self] in
            if fromEvent { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let (available, result) = await Task.detached(priority: .utility) {
                var directory: ObjCBool = false
                let available = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                return (available, available ? FolderEntry.list(url) : [])
            }.value
            guard !Task.isCancelled, let self else { return }
            let changed = self.entries != result || self.isAvailable != available
            if changed {
                self.isAvailable = available
                self.entries = result
            }
            self.refreshTask = nil
            if !initial && (changed || fromEvent) { self.onChange(url) }
        }
    }
}

private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let action: () -> Void

    init(root: URL, action: @escaping () -> Void) {
        self.root = root.path
        self.action = action
        let parent = root.deletingLastPathComponent()
        let paths = [root.path, parent.path] as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let events = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if events.contains(where: { $0 == watcher.root || $0.hasPrefix(watcher.root + "/") }) {
                watcher.action()
            }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.18, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
