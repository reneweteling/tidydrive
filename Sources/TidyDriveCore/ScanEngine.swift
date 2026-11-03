import Foundation

public struct ScanSettings: Codable, Equatable, Sendable {
    /// Folders that hold your projects, e.g. ~/projects.
    public var projectRoots: [String]
    /// A project untouched for this many days counts as stale.
    public var staleDays: Int
    /// Files above this size in a project folder are listed as large files.
    public var largeFileBytes: Int64
    /// Categories to scan. Empty means all.
    public var categories: Set<Category>

    public init(projectRoots: [String], staleDays: Int = 60, largeFileBytes: Int64 = 500 * 1_000_000,
                categories: Set<Category> = Set(Category.allCases)) {
        self.projectRoots = projectRoots
        self.staleDays = staleDays
        self.largeFileBytes = largeFileBytes
        self.categories = categories
    }

    /// The first of the usual project folders that exists.
    public static func defaultProjectRoots(home: String) -> [String] {
        let candidates = ["projects", "Projects", "Developer", "dev", "code", "Code", "src", "repos", "git", "workspace", "Sites"]
        let found = candidates.map { "\(home)/\($0)" }.filter { FileSystem.isDirectory($0) }
        return found.isEmpty ? [] : [found[0]]
    }
}

public struct ScanContext: Sendable {
    public let home: String
    public let settings: ScanSettings
    public let shell: Shell
    public let now: Date

    public init(home: String, settings: ScanSettings, shell: Shell, now: Date = Date()) {
        self.home = home
        self.settings = settings
        self.shell = shell
        self.now = now
    }

    public func path(_ relative: String) -> String {
        relative.hasPrefix("/") ? relative : "\(home)/\(relative)"
    }

    /// "~/Library/Caches/pip" for display.
    public func tilde(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

public protocol Scanner: Sendable {
    var category: Category { get }
    func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote])
}

public final class ScanEngine: Sendable {
    public let scanners: [any Scanner]

    public init(scanners: [any Scanner] = ScanEngine.allScanners) {
        self.scanners = scanners
    }

    public static var allScanners: [any Scanner] {
        [XcodeScanner(), SimulatorScanner(), ProjectScanner(), CacheScanner(), ModelScanner(),
         ToolchainScanner(), DockerScanner(), AndroidScanner()]
    }

    /// Runs every enabled scanner in parallel. `progress` is called with the
    /// category each time a scanner finishes.
    public func scan(_ context: ScanContext, progress: (@Sendable (Category, Int, Int) -> Void)? = nil) async -> ScanResult {
        let started = Date()
        // The project scanner also produces large files, so it runs when
        // either of the two is enabled.
        let enabled = scanners.filter {
            context.settings.categories.contains($0.category)
                || ($0.category == .projects && context.settings.categories.contains(.largeFiles))
        }
        let total = enabled.count
        let counter = Counter()

        let collected = await withTaskGroup(of: ([CleanupItem], [ScanNote]).self) { group in
            for scanner in enabled {
                group.addTask {
                    // Scanners block on disk and child processes, so they run
                    // on GCD threads instead of Swift's small cooperative pool.
                    let result = await Self.offload { scanner.scan(context) }
                    let done = counter.increment()
                    progress?(scanner.category, done, total)
                    return result
                }
            }
            var items: [CleanupItem] = []
            var notes: [ScanNote] = []
            for await (i, n) in group {
                items += i
                notes += n
            }
            return (items, notes)
        }

        var seen = Set<String>()
        let items = collected.0
            .filter { context.settings.categories.contains($0.category) }
            .filter { $0.size > 0 && seen.insert($0.id).inserted }
            .sorted { $0.size > $1.size }
        return ScanResult(items: items, notes: collected.1, finishedAt: Date(), duration: Date().timeIntervalSince(started))
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

extension ScanEngine {
    static func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}

/// Measures several folders at once. Sizing is the slow part of a scan.
enum Sizer {
    static func sizes(_ paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        var values = [Int64](repeating: 0, count: paths.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let size = FileSystem.allocatedSize(of: URL(fileURLWithPath: paths[i]))
            lock.lock(); values[i] = size; lock.unlock()
        }
        var result: [String: Int64] = [:]
        for (i, p) in paths.enumerated() { result[p] = values[i] }
        return result
    }
}
