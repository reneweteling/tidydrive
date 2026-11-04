import Foundation

/// Walks the project folders for regenerable dependencies and build output,
/// and for large files.
public struct ProjectScanner: Scanner {
    public let category: Category = .projects
    let maxDepth = 6

    public init() {}

    struct Found {
        var projectRoot: String
        var ecosystem: String
        var path: String
    }

    struct ProjectInfo {
        var lastActivity: Date?
        var dirty: Bool
        var isGit: Bool
    }

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let roots = context.settings.projectRoots.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) }
            .filter { FileSystem.isDirectory($0) }
        guard !roots.isEmpty else {
            return ([], [ScanNote(category: .projects, message: "No project folder set. Add one in Settings, Projects.")])
        }

        var found: [Found] = []
        for root in roots {
            for child in FileSystem.subdirectories(of: root) where !child.hasPrefix(".") {
                walk("\(root)/\(child)", depth: 1, projectRoot: "\(root)/\(child)", into: &found)
            }
        }

        // Drop anything git tracks: a committed vendor/ or dist/ is source.
        let projects = Set(found.map(\.projectRoot))
        var infos: [String: ProjectInfo] = [:]
        for project in projects { infos[project] = projectInfo(project, context: context, found: found) }
        let kept = Set(context.settings.keptProjects.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) })
        found = found.filter { !Self.isKept($0.projectRoot, kept) }
        found = found.filter { !isTracked($0.path, in: $0.projectRoot, git: infos[$0.projectRoot]?.isGit == true, context: context) }
        let sizes = Sizer.sizes(found.map(\.path))
        let staleDays = context.settings.staleDays
        var items: [CleanupItem] = []
        for f in found {
            let info = infos[f.projectRoot] ?? ProjectInfo(lastActivity: nil, dirty: false, isGit: false)
            let age = info.lastActivity.map { Int(context.now.timeIntervalSince($0) / 86_400) }
            let stale = !info.dirty && (age ?? 0) >= staleDays
            let projectName = (f.projectRoot as NSString).lastPathComponent
            let relative = String(f.path.dropFirst(f.projectRoot.count + 1))
            var detail = f.ecosystem
            if info.dirty {
                detail += " · uncommitted changes"
            } else if let age {
                detail += info.isGit ? " · last commit \(Self.ago(age))" : " · last change \(Self.ago(age))"
            }
            items.append(CleanupItem(
                id: "project:\(f.path)",
                category: .projects,
                group: stale ? "Stale, untouched for \(staleDays)+ days" : "Active",
                title: "\(projectName)/\(relative)",
                detail: detail,
                path: f.path,
                size: sizes[f.path] ?? 0,
                risk: .rebuild,
                selectedByDefault: stale,
                action: .delete([f.path]),
                project: f.projectRoot
            ))
        }

        if context.settings.categories.contains(.largeFiles) {
            items += largeFiles(roots: roots, context: context).filter { !Self.isKept($0.path ?? "", kept) }
        }
        var notes: [ScanNote] = []
        if !kept.isEmpty {
            notes.append(ScanNote(category: .projects, message: "\(kept.count) kept project\(kept.count == 1 ? " is" : "s are") left alone. Manage them in Settings, Projects."))
        }
        return (items, notes)
    }

    // MARK: - Walking

    private func walk(_ dir: String, depth: Int, projectRoot: String, into found: inout [Found]) {
        let names = FileSystem.children(of: dir)
        let nameSet = Set(names)
        var project = projectRoot
        // A nested git repository (a monorepo checkout inside a folder of
        // checkouts) is its own project.
        if depth > 1, nameSet.contains(".git") { project = dir }

        var claimed = Set<String>()
        for rule in ProjectRules.all where rule.matchesMarker(in: nameSet) {
            for artifact in rule.artifacts(in: names) where !claimed.contains(artifact) {
                let path = "\(dir)/\(artifact)"
                guard isRealDirectory(path) else { continue }
                claimed.insert(artifact)
                // The top segment of a nested artifact (tmp in tmp/cache) is
                // still walked, but the artifact itself is not.
                found.append(Found(projectRoot: project, ecosystem: rule.ecosystem, path: path))
            }
        }

        guard depth < maxDepth else { return }
        for name in names {
            if name.hasPrefix(".") || claimed.contains(name) || ProjectRules.skipWhileWalking.contains(name) { continue }
            let path = "\(dir)/\(name)"
            guard isRealDirectory(path) else { continue }
            if name.hasSuffix(".app") || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") { continue }
            walk(path, depth: depth + 1, projectRoot: project, into: &found)
        }
    }

    private func isRealDirectory(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    // MARK: - Project state

    private func projectInfo(_ root: String, context: ScanContext, found: [Found]) -> ProjectInfo {
        if FileSystem.exists("\(root)/.git") {
            let log = context.shell.run("git", ["-C", root, "log", "-1", "--format=%ct"], timeout: 15)
            let status = context.shell.run("git", ["-C", root, "status", "--porcelain", "--untracked-files=no"], timeout: 30)
            let last = Double(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) }
            let dirty = status.succeeded && !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ProjectInfo(lastActivity: last ?? FileSystem.modificationDate(root), dirty: dirty, isGit: true)
        }
        // Without git, the newest top-level entry that is not build output.
        let artifacts = Set(found.filter { $0.projectRoot == root }.map { ($0.path as NSString).lastPathComponent })
        let dates = FileSystem.children(of: root)
            .filter { !artifacts.contains($0) && $0 != ".DS_Store" }
            .compactMap { FileSystem.modificationDate("\(root)/\($0)") }
        return ProjectInfo(lastActivity: dates.max() ?? FileSystem.modificationDate(root), dirty: false, isGit: false)
    }

    private func isTracked(_ path: String, in root: String, git: Bool, context: ScanContext) -> Bool {
        guard git else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        let result = context.shell.run("git", ["-C", root, "ls-files", "--", relative], timeout: 15)
        return result.succeeded && !result.stdout.isEmpty
    }

    // MARK: - Large files

    private func largeFiles(roots: [String], context: ScanContext) -> [CleanupItem] {
        let threshold = context.settings.largeFileBytes
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .isPackageKey]
        let skip = ProjectRules.skipWhileWalking.union(Set(ProjectRules.all.flatMap(\.artifacts).filter { !$0.contains("*") && !$0.contains("/") }))
        var items: [CleanupItem] = []
        let paths = spotlightLargeFiles(roots: roots, threshold: threshold, context: context)
            ?? enumerateLargeFiles(roots: roots, threshold: threshold, keys: keys, skip: skip)

        for (path, root) in paths {
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  let size = v.totalFileAllocatedSize, Int64(size) >= threshold else { continue }
            let segments = Set(path.split(separator: "/").map(String.init))
            if !segments.isDisjoint(with: ["node_modules", ".git", ".build", "DerivedData", "Pods"]) { continue }
            items.append(largeFileItem(path: path, root: root, size: Int64(size), modified: v.contentModificationDate, context: context))
        }
        return items
    }

    /// Spotlight answers in a fraction of a second where walking every file
    /// takes minutes. Returns nil when Spotlight is off for the volume, so
    /// the caller walks instead.
    private func spotlightLargeFiles(roots: [String], threshold: Int64, context: ScanContext) -> [(String, String)]? {
        let status = context.shell.run("/usr/bin/mdutil", ["-s", "/"], timeout: 10)
        guard status.succeeded, status.stdout.contains("Indexing enabled") else { return nil }
        var result: [(String, String)] = []
        for root in roots {
            let found = context.shell.run("/usr/bin/mdfind", ["-onlyin", root, "kMDItemFSSize > \(threshold)"], timeout: 30)
            guard found.succeeded else { return nil }
            result += found.stdout.split(whereSeparator: \.isNewline).map { (String($0), root) }
        }
        return result
    }

    private func enumerateLargeFiles(roots: [String], threshold: Int64, keys: [URLResourceKey], skip: Set<String>) -> [(String, String)] {
        var result: [(String, String)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isSymbolicLink == true { continue }
                if v.isDirectory == true {
                    if skip.contains(url.lastPathComponent) || v.isPackage == true { enumerator.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true, let size = v.totalFileAllocatedSize, Int64(size) >= threshold else { continue }
                result.append((url.path, root))
            }
        }
        return result
    }

    private func largeFileItem(path: String, root: String, size: Int64, modified: Date?, context: ScanContext) -> CleanupItem {
        let age = modified.map { Int(context.now.timeIntervalSince($0) / 86_400) }
        var detail = ByteFormat.string(size)
        if let age { detail += " · changed \(Self.ago(age))" }
        if let repo = gitRoot(of: path, stopAt: root) {
            let rel = String(path.dropFirst(repo.count + 1))
            if context.shell.run("git", ["-C", repo, "ls-files", "--error-unmatch", "--", rel], timeout: 10).succeeded {
                detail += " · tracked in git"
            }
        }
        detail += " · goes to the Trash"
        let relative = path.dropFirst(root.count + 1)
        let project = gitRoot(of: path, stopAt: root) ?? relative.split(separator: "/").first.map { "\(root)/\($0)" }
        return CleanupItem(
            id: "large:\(path)",
            category: .largeFiles,
            group: "Large files in your projects",
            title: context.tilde(path).replacingOccurrences(of: context.tilde(root) + "/", with: ""),
            detail: detail,
            path: path,
            size: size,
            risk: .careful,
            selectedByDefault: false,
            action: .trash([path]),
            project: project
        )
    }

    private func gitRoot(of path: String, stopAt root: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count >= root.count {
            if FileSystem.exists("\(dir)/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// True when `path` is a kept project or lies inside one.
    static func isKept(_ path: String, _ kept: Set<String>) -> Bool {
        kept.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func ago(_ days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(days) days ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }
}

func expandTilde(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
}
