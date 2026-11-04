import Foundation
import UniformTypeIdentifiers

/// Finds videos and photos in the media folders. Spotlight answers in well
/// under a second; walking is the fallback when indexing is off.
public enum MediaLocator {
    public enum Kind: String, Sendable { case video, image }

    /// Folders that are libraries of an app. Changing files inside them
    /// corrupts the library, so nothing in here is ever offered.
    static let packageSuffixes = [".photoslibrary", ".fcpbundle", ".imovielibrary", ".tvlibrary", ".musiclibrary",
                                  ".aplibrary", ".migratedphotolibrary", ".photolibrary", ".app", ".bundle",
                                  ".xcarchive", ".lrdata", ".cocatalog", ".logicx", ".band"]
    static let skipNames: Set<String> = ["node_modules", ".git", "Library", ".Trash", "Pods", "DerivedData", ".build",
                                         "vendor", "target", ".venv", "venv", "dist", "build", ".next"]

    public static func defaultFolders(home: String) -> [String] {
        ["Movies", "Desktop", "Downloads", "Documents", "Pictures"].map { "\(home)/\($0)" }
    }

    /// Files of `kind` at least `minSize` bytes under `folders`.
    public static func find(_ kind: Kind, in folders: [String], minSize: Int64, shell: Shell) -> [String] {
        let existing = folders.filter(FileSystem.isDirectory)
        let paths = spotlight(kind, in: existing, minSize: minSize, shell: shell) ?? walk(kind, in: existing, minSize: minSize)
        var seen = Set<String>()
        return paths.filter { isEligible($0) && seen.insert($0).inserted }
    }

    public static func isEligible(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        for c in components.dropLast() {
            if skipNames.contains(c) { return false }
            if c.hasPrefix(".") { return false }
            if packageSuffixes.contains(where: { c.lowercased().hasSuffix($0) }) { return false }
        }
        return true
    }

    /// The git work tree a file lives in, if any. Media inside a repository
    /// is source (website assets, fixtures), so it is never converted.
    public static func isInsideGitRepo(_ path: String, home: String) -> Bool {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > home.count {
            if FileSystem.exists("\(dir)/.git") { return true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    private static func spotlight(_ kind: Kind, in folders: [String], minSize: Int64, shell: Shell) -> [String]? {
        let status = shell.run("/usr/bin/mdutil", ["-s", "/"], timeout: 10)
        guard status.succeeded, status.stdout.contains("Indexing enabled") else { return nil }
        let type = kind == .video ? "public.movie" : "public.image"
        var result: [String] = []
        for folder in folders {
            let found = shell.run("/usr/bin/mdfind", ["-onlyin", folder, "kMDItemContentTypeTree == '\(type)' && kMDItemFSSize >= \(minSize)"],
                                  timeout: 60)
            guard found.succeeded else { return nil }
            result += found.stdout.split(whereSeparator: \.isNewline).map(String.init)
        }
        return result
    }

    private static func walk(_ kind: Kind, in folders: [String], minSize: Int64) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey]
        var result: [String] = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    if skipNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true, Int64(v.fileSize ?? 0) >= minSize, let type = v.contentType else { continue }
                let match = kind == .video ? type.conforms(to: .movie) : type.conforms(to: .image)
                if match { result.append(url.path) }
            }
        }
        return result
    }
}
