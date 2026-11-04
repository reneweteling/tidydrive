import Foundation

/// One folder, file or package in the disk map. Only items of a meaningful
/// size are kept as nodes; the rest of a folder is folded into a single
/// synthetic "Smaller items" child so memory stays bounded.
public final class DiskNode: Identifiable, @unchecked Sendable {
    public static let smallerItemsName = "Smaller items"

    public let path: String
    public let name: String
    public internal(set) var size: Int64
    public let isDirectory: Bool
    /// A bundle such as .app or .photoslibrary. Sized, but never opened.
    public let isPackage: Bool
    /// The "Smaller items" bucket. Not a real path, cannot be trashed.
    public let isSynthetic: Bool
    /// Number of items folded into a synthetic node.
    public let itemCount: Int
    public internal(set) var children: [DiskNode]
    public weak internal(set) var parent: DiskNode?

    public var id: String { isSynthetic ? path + "#smaller" : path }

    public init(path: String, name: String? = nil, size: Int64, isDirectory: Bool, isPackage: Bool = false,
                isSynthetic: Bool = false, itemCount: Int = 0, children: [DiskNode] = []) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.size = size
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSynthetic = isSynthetic
        self.itemCount = itemCount
        self.children = children
        for c in children { c.parent = self }
    }

    /// Folders the user can drill into.
    public var isBrowsable: Bool { isDirectory && !isPackage && !isSynthetic && !children.isEmpty }

    /// Chain from the root down to this node.
    public var ancestry: [DiskNode] {
        var chain: [DiskNode] = [self]
        var node = self
        while let p = node.parent { chain.append(p); node = p }
        return chain.reversed()
    }

    /// Removes `child` and subtracts its size from this node and every ancestor.
    public func remove(_ child: DiskNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        child.parent = nil
        var node: DiskNode? = self
        while let n = node {
            n.size = max(0, n.size - child.size)
            node = n.parent
        }
    }
}

public enum DiskMapScanner {
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "framework",
        "bundle", "plugin", "xcarchive", "xcodeproj", "xcworkspace", "playground", "sparsebundle",
        "sparseimage", "kext", "appex", "prefpane", "qlgenerator", "lproj", "pkg", "dSYM", "aplibrary",
        "theatre", "logicx", "band", "imovieproj", "tvlibrary", "vmwarevm", "pvm", "utm"
    ]

    static let skippedPaths: [String] = ["/System", "/Volumes", "/dev", "/private/var/vm"]

    /// One traversal of `root`. Folders and files under `minNodeSize` are
    /// folded into one "Smaller items" node per folder. `progress` receives
    /// the bytes counted so far, a few times a second.
    public static func scan(root: String, minNodeSize: Int64 = 20_000_000,
                            progress: @escaping @Sendable (Int64) -> Void) async -> DiskNode {
        let state = ScanState(minNodeSize: minNodeSize)
        let normalized = normalizedRoot(root)

        let poller = Task.detached {
            while !Task.isCancelled {
                progress(state.bytes)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        let node: DiskNode = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var st = stat()
                if lstat(normalized, &st) == 0 {
                    state.devices.insert(st.st_dev)
                    if normalized == "/" {
                        var data = stat()
                        if lstat("/System/Volumes/Data", &data) == 0 { state.devices.insert(data.st_dev) }
                    }
                }
                cont.resume(returning: scanDirectory(path: normalized, name: normalized == "/" ? "/" : nil,
                                                     depth: 0, state: state))
            }
        }
        poller.cancel()
        progress(state.bytes)
        return node
    }

    private static func normalizedRoot(_ root: String) -> String {
        var p = (root as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    final class ScanState: @unchecked Sendable {
        let minNodeSize: Int64
        var devices: Set<dev_t> = []
        private let lock = NSLock()
        private var counted: Int64 = 0
        init(minNodeSize: Int64) { self.minNodeSize = minNodeSize }
        var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return counted }
        func add(_ n: Int64) { lock.lock(); counted += n; lock.unlock() }
    }

    private struct Entry {
        let path: String
        let name: String
        let isDir: Bool
        let size: Int64
    }

    private static func isSkipped(_ path: String) -> Bool {
        skippedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && packageExtensions.contains(ext)
    }

    /// Lists a directory with lstat on every entry. Files get their size now,
    /// directories on the same volume are returned for recursion.
    private static func list(_ path: String, state: ScanState) -> [Entry] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var entries: [Entry] = []
        var fileBytes: Int64 = 0
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let full = path == "/" ? "/" + name : path + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR {
                guard state.devices.contains(st.st_dev), !isSkipped(full) else { continue }
                entries.append(Entry(path: full, name: name, isDir: true, size: 0))
            } else if mode == S_IFREG {
                let size = Int64(st.st_blocks) * 512
                fileBytes += size
                entries.append(Entry(path: full, name: name, isDir: false, size: size))
            }
            // Symlinks, sockets and devices count as zero.
        }
        state.add(fileBytes)
        return entries
    }

    /// Total bytes below a directory, without building nodes (packages).
    private static func totalSize(of path: String, state: ScanState) -> Int64 {
        var total: Int64 = 0
        for e in list(path, state: state) {
            total += e.isDir ? totalSize(of: e.path, state: state) : e.size
        }
        return total
    }

    private static func scanDirectory(path: String, name: String?, depth: Int, state: ScanState) -> DiskNode {
        let entries = list(path, state: state)
        var subdirs: [Entry] = []
        var kept: [DiskNode] = []
        var smallBytes: Int64 = 0
        var smallCount = 0

        for e in entries {
            if e.isDir { subdirs.append(e); continue }
            if e.size >= state.minNodeSize {
                kept.append(DiskNode(path: e.path, name: e.name, size: e.size, isDirectory: false))
            } else {
                smallBytes += e.size
                smallCount += 1
            }
        }

        // Fan out over the first levels; deeper folders run on the calling thread.
        var results = [DiskNode?](repeating: nil, count: subdirs.count)
        let build: (Int) -> DiskNode = { i in
            let e = subdirs[i]
            if isPackage(e.name) {
                let size = totalSize(of: e.path, state: state)
                return DiskNode(path: e.path, name: e.name, size: size, isDirectory: true, isPackage: true)
            }
            return scanDirectory(path: e.path, name: e.name, depth: depth + 1, state: state)
        }
        if depth < 3, subdirs.count > 1 {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                let node = build(i)
                lock.lock(); results[i] = node; lock.unlock()
            }
        } else {
            for i in subdirs.indices { results[i] = build(i) }
        }

        for case let node? in results {
            if node.size >= state.minNodeSize {
                kept.append(node)
            } else {
                smallBytes += node.size
                smallCount += 1
            }
        }

        if smallBytes > 0 {
            kept.append(DiskNode(path: path, name: DiskNode.smallerItemsName, size: smallBytes, isDirectory: false,
                                 isSynthetic: true, itemCount: smallCount))
        }
        kept.sort { $0.size > $1.size }
        let total = kept.reduce(Int64(0)) { $0 + $1.size }
        return DiskNode(path: path, name: name, size: total, isDirectory: true, children: kept)
    }
}
