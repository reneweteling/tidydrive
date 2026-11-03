import Foundation

public enum FileSystem {
    /// Bytes a folder (or file) actually takes on disk. Does not follow
    /// symlinks, so a pnpm-linked node_modules is not counted twice.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Child directory names, without hidden-file filtering.
    public static func subdirectories(of path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { isDirectory((path as NSString).appendingPathComponent($0)) }.sorted()
    }

    public static func children(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Bytes still free for "important" use, which is what Finder shows.
    public static func diskStatus(for path: String = "/") -> DiskStatus? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return DiskStatus(name: v.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), available: available)
    }
}

public struct DiskStatus: Codable, Equatable, Sendable {
    public var name: String
    public var total: Int64
    public var available: Int64

    public init(name: String, total: Int64, available: Int64) {
        self.name = name
        self.total = total
        self.available = max(0, available)
    }

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var usedPercent: Int { Int((usedFraction * 100).rounded()) }
}

/// Fires once when usage crosses `threshold`, then stays quiet until usage
/// has dropped below `reset`. Without the gap a disk hovering around 90%
/// would notify on every check.
public struct ThresholdAlarm: Codable, Equatable, Sendable {
    public var threshold: Double
    public var reset: Double
    public private(set) var armed: Bool

    public init(threshold: Double = 0.90, reset: Double = 0.85, armed: Bool = true) {
        self.threshold = threshold
        self.reset = min(reset, threshold)
        self.armed = armed
    }

    /// Returns true when the caller should notify.
    public mutating func update(usedFraction: Double) -> Bool {
        if armed, usedFraction >= threshold {
            armed = false
            return true
        }
        if !armed, usedFraction < reset {
            armed = true
        }
        return false
    }
}
