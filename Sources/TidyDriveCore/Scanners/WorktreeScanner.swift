import Foundation

/// Git worktrees: extra checkouts of a repository, often made by coding
/// agents (Claude Code puts them in .claude/worktrees). Each one carries its
/// own node_modules or .venv, so a hundred of them add up to hundreds of GB.
///
/// Removing one runs `git worktree remove`: the folder goes, the branch and
/// its commits stay in the repository.
public struct WorktreeScanner: Scanner {
    public let category: Category = .worktrees
    public init() {}

    struct Worktree {
        var path: String
        var branch: String?
        var head: String?
        var prunable: Bool
        var locked: Bool
    }

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let roots = context.settings.projectRoots.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) }
            .filter(FileSystem.isDirectory)
        let kept = Set(context.settings.keptProjects.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) })
        let repos = Self.findRepositories(in: roots)

        var found: [(repo: String, worktree: Worktree, base: String, merged: Set<String>)] = []
        for repo in repos {
            let list = context.shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 30)
            guard list.succeeded else { continue }
            let worktrees = Self.parse(list.stdout).filter { SafetyGuard.normalize($0.path) != repo }
            guard !worktrees.isEmpty else { continue }
            let base = Self.defaultBranch(repo, shell: context.shell)
            let mergedOut = context.shell.run("git", ["-C", repo, "branch", "--format=%(refname:short)", "--merged", base], timeout: 30)
            let merged = Set(mergedOut.stdout.split(whereSeparator: \.isNewline).map(String.init))
            for wt in worktrees where !wt.locked && !ProjectScanner.isKept(wt.path, kept) && !ProjectScanner.isKept(repo, kept) {
                found.append((repo, wt, base, merged))
            }
        }

        let existing = found.filter { FileSystem.isDirectory($0.worktree.path) }
        let sizes = Sizer.sizes(existing.map(\.worktree.path))
        var items: [CleanupItem] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: existing.count) { i in
            let (repo, wt, base, merged) = existing[i]
            let status = context.shell.run("git", ["-C", wt.path, "status", "--porcelain"], timeout: 60)
            let dirty = status.succeeded && !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let last = Double(context.shell.run("git", ["-C", wt.path, "log", "-1", "--format=%ct"], timeout: 15).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) }
            let age = last.map { Int(context.now.timeIntervalSince($0) / 86_400) }
            let isMerged = wt.branch.map { merged.contains($0) } ?? false
            let stale = (age ?? 0) >= 14
            // A detached HEAD keeps nothing alive: its commits are only safe
            // when some branch also contains them.
            var orphanCommits = false
            if wt.branch == nil, let head = wt.head {
                let contains = context.shell.run("git", ["-C", repo, "branch", "--all", "--contains", head], timeout: 30)
                orphanCommits = !(contains.succeeded && !contains.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            let risky = dirty || orphanCommits

            var detail = wt.branch.map { "branch \($0)" } ?? "detached HEAD"
            if isMerged { detail += " · merged into \(base)" }
            if let age { detail += " · last commit \(ProjectScanner.ago(age))" }
            if dirty { detail += " · uncommitted changes, these are lost" }
            if orphanCommits { detail += " · commits on no branch, these are lost" }
            if !risky { detail += wt.branch == nil ? " · its commits are on a branch" : " · the branch and its commits stay" }

            // --force only for the ones with changes, which the user has to
            // pick one by one: they are Careful and never preselected.
            var args = ["-C", repo, "worktree", "remove"]
            if dirty { args.append("--force") }
            args.append(wt.path)
            let repoName = (repo as NSString).lastPathComponent
            let item = CleanupItem(
                id: "worktree:\(wt.path)", category: .worktrees, group: repoName,
                title: Self.label(wt.path, repo: repo), detail: detail, path: wt.path, size: sizes[wt.path] ?? 0,
                risk: risky ? .careful : .rebuild, selectedByDefault: !risky && (isMerged || stale),
                action: .commands([Command("git", args)], fallbackDelete: []),
                project: repo
            )
            lock.lock(); items.append(item); lock.unlock()
        }

        var notes: [ScanNote] = []
        if !items.isEmpty {
            let agent = items.filter { $0.path?.contains("/.claude/worktrees/") == true }.count
            if agent > 0 {
                notes.append(ScanNote(category: .worktrees, message: "\(agent) of these were made by coding agents in .claude/worktrees."))
            }
        }
        return (items, notes)
    }

    /// "collabcenter: .claude/worktrees/agent-1234" or "cc-trial-1560".
    static func label(_ path: String, repo: String) -> String {
        let repoName = (repo as NSString).lastPathComponent
        if path.hasPrefix(repo + "/") { return "\(repoName)/\(path.dropFirst(repo.count + 1))" }
        return (path as NSString).lastPathComponent
    }

    /// Main repositories (a .git folder, not a .git file) a few levels deep.
    static func findRepositories(in roots: [String]) -> [String] {
        var repos: [String] = []
        func visit(_ dir: String, depth: Int) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(dir)/.git", isDirectory: &isDir), isDir.boolValue {
                repos.append(dir)
                return
            }
            guard depth < 4 else { return }
            for child in FileSystem.subdirectories(of: dir) where !child.hasPrefix(".") && !ProjectRules.skipWhileWalking.contains(child) {
                visit("\(dir)/\(child)", depth: depth + 1)
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return repos
    }

    static func parse(_ porcelain: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = Worktree(path: String(line.dropFirst(9)), branch: nil, head: nil, prunable: false, locked: false)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch refs/heads/") {
                current?.branch = String(line.dropFirst(18))
            } else if line.hasPrefix("prunable") {
                current?.prunable = true
            } else if line.hasPrefix("locked") {
                current?.locked = true
            }
        }
        if let current { result.append(current) }
        return result
    }

    static func defaultBranch(_ repo: String, shell: Shell) -> String {
        let head = shell.run("git", ["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: 10)
        if head.succeeded {
            let ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        for name in ["main", "master", "develop"] where shell.run("git", ["-C", repo, "rev-parse", "--verify", "--quiet", name], timeout: 10).succeeded {
            return name
        }
        return "HEAD"
    }
}
