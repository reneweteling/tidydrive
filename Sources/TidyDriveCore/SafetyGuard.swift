import Foundation

/// Last line of defence before anything is removed. Scanners only ever
/// produce paths they found themselves, but a bug in a rule must not be able
/// to point a delete at a home folder, a project root or the system.
public struct SafetyGuard: Sendable {
    public let home: String
    public let protectedRoots: Set<String>

    public init(home: String, projectRoots: [String]) {
        self.home = SafetyGuard.normalize(home)
        self.protectedRoots = Set(projectRoots.map(SafetyGuard.normalize))
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    public func check(_ rawPath: String, forTrash: Bool = false) -> Verdict {
        guard rawPath.hasPrefix("/") else { return .refused("not an absolute path") }
        let path = SafetyGuard.normalize(rawPath)
        if path.split(separator: "/").contains("..") { return .refused("path contains ..") }

        // Xcode apps are the only thing outside the home folder we touch,
        // and only by moving them to the Trash.
        if forTrash, path.hasPrefix("/Applications/Xcode"), path.hasSuffix(".app") {
            return .allowed
        }

        guard path.hasPrefix(home + "/") else { return .refused("outside the home folder") }

        let relative = path.dropFirst(home.count + 1).split(separator: "/")
        if relative.count < 2 {
            // ~/Library, ~/projects, ~/.npm itself: only a handful of
            // well-known cache folders may go as a whole.
            let allowedTopLevel: Set<String> = [".npm", ".gradle", ".m2", ".ivy2", ".sbt", ".stack", ".pub-cache",
                                                ".hex", ".mix", ".bun", ".nuget", ".cache", "fvm"]
            guard let first = relative.first, allowedTopLevel.contains(String(first)) else {
                return .refused("too close to the home folder")
            }
        }

        let protectedHome: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                                          "Library", "Applications", "Public", ".ssh", ".gnupg", ".config"]
        if relative.count == 1, protectedHome.contains(String(relative[0])) {
            return .refused("a personal folder")
        }
        if relative.count >= 2, relative[0] == "Library",
           ["Mobile Documents", "Mail", "Messages", "Keychains", "Photos", "CloudStorage"].contains(String(relative[1])) {
            return .refused("personal data in Library")
        }

        if protectedRoots.contains(path) { return .refused("a project folder itself") }
        for root in protectedRoots where root.hasPrefix(path + "/") {
            return .refused("contains your project folder \(root)")
        }
        return .allowed
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
