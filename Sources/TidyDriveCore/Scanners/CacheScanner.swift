import Foundation

public struct CacheScanner: Scanner {
    public let category: Category = .caches

    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        var candidates: [(CacheRule, [String])] = []
        for rule in CacheRules.all {
            let existing = rule.paths.map(context.path).filter(FileSystem.exists)
            if !existing.isEmpty { candidates.append((rule, existing)) }
        }
        let sizes = Sizer.sizes(candidates.flatMap(\.1))

        var items: [CleanupItem] = candidates.map { rule, paths in
            let size = paths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            let action: CleanupAction
            if let command = rule.command, context.shell.has(command.executable) {
                action = .commands([command], fallbackDelete: paths)
            } else {
                action = .delete(paths)
            }
            var detail = paths.map(context.tilde).joined(separator: ", ")
            if let note = rule.note { detail += " · \(note)" }
            return CleanupItem(
                id: "cache:\(rule.id)", category: .caches, group: rule.group, title: rule.name, detail: detail,
                path: paths.first, size: size, risk: rule.risk, selectedByDefault: rule.selected, action: action
            )
        }

        items += playwrightOldBuilds(context)
        items += jetBrainsOldVersions(context)
        items += editorCaches(context)
        return (items, [])
    }

    /// Playwright keeps every browser build it ever downloaded
    /// (chromium-1140, chromium-1148...). Only the newest per browser is used.
    private func playwrightOldBuilds(_ context: ScanContext) -> [CleanupItem] {
        let root = context.path("Library/Caches/ms-playwright")
        let builds = FileSystem.subdirectories(of: root).filter { !$0.hasPrefix(".") }
        var byBrowser: [String: [(name: String, build: Int)]] = [:]
        for name in builds {
            guard let dash = name.lastIndex(of: "-"), let build = Int(name[name.index(after: dash)...]) else { continue }
            byBrowser[String(name[..<dash]), default: []].append((name, build))
        }
        let old = byBrowser.values.flatMap { list in list.sorted { $0.build > $1.build }.dropFirst().map(\.name) }
        guard !old.isEmpty else { return [] }
        let paths = old.map { "\(root)/\($0)" }
        let sizes = Sizer.sizes(paths)
        return [CleanupItem(
            id: "cache:playwright-old", category: .caches, group: "Testing", title: "Old Playwright browsers",
            detail: "\(old.sorted().joined(separator: ", ")) · the newest build of each browser stays",
            path: root, size: sizes.values.reduce(0, +), risk: .safe, selectedByDefault: true, action: .delete(paths)
        )]
    }

    /// JetBrains keeps caches per IDE version, e.g. IntelliJIdea2024.1.
    private func jetBrainsOldVersions(_ context: ScanContext) -> [CleanupItem] {
        var items: [CleanupItem] = []
        for base in ["Library/Caches/JetBrains", "Library/Logs/JetBrains"] {
            let root = context.path(base)
            var byProduct: [String: [String]] = [:]
            for name in FileSystem.subdirectories(of: root) {
                guard let firstDigit = name.firstIndex(where: \.isNumber) else { continue }
                byProduct[String(name[..<firstDigit]), default: []].append(name)
            }
            let old = byProduct.values.flatMap { list in
                list.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.dropFirst()
            }
            guard !old.isEmpty else { continue }
            let paths = old.map { "\(root)/\($0)" }
            let sizes = Sizer.sizes(paths)
            items.append(CleanupItem(
                id: "cache:\(base)", category: .caches, group: "Editors",
                title: base.hasPrefix("Library/Logs") ? "Old JetBrains logs" : "Old JetBrains caches",
                detail: "\(old.sorted().joined(separator: ", ")) · the newest version of each IDE stays",
                path: root, size: sizes.values.reduce(0, +), risk: .safe, selectedByDefault: true, action: .delete(paths)
            ))
        }
        return items
    }

    /// VS Code and Cursor keep a workspaceStorage folder per project ever
    /// opened. Folders for projects that no longer exist are dead weight.
    private func editorCaches(_ context: ScanContext) -> [CleanupItem] {
        let editors = [("Cursor", "Cursor"), ("VS Code", "Code"), ("Windsurf", "Windsurf"), ("VSCodium", "VSCodium")]
        var items: [CleanupItem] = []
        for (name, folder) in editors {
            let support = context.path("Library/Application Support/\(folder)")
            guard FileSystem.isDirectory(support) else { continue }

            let storage = "\(support)/User/workspaceStorage"
            var orphans: [String] = []
            for id in FileSystem.subdirectories(of: storage) {
                guard let json = FileSystem.readText("\(storage)/\(id)/workspace.json"),
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uri = (object["folder"] ?? object["workspace"]) as? String,
                      uri.hasPrefix("file://"),
                      let url = URL(string: uri) else { continue }
                if !FileSystem.exists(url.path) { orphans.append("\(storage)/\(id)") }
            }
            if !orphans.isEmpty {
                let sizes = Sizer.sizes(orphans)
                items.append(CleanupItem(
                    id: "cache:\(folder)-workspaces", category: .caches, group: "Editors",
                    title: "\(name) data for deleted projects",
                    detail: "\(orphans.count) workspace folders whose project no longer exists",
                    path: storage, size: sizes.values.reduce(0, +), risk: .safe, selectedByDefault: true,
                    action: .delete(orphans)
                ))
            }

            let cached = ["CachedData", "CachedExtensionVSIXs", "Cache", "Code Cache", "GPUCache"]
                .map { "\(support)/\($0)" }.filter(FileSystem.exists)
            if !cached.isEmpty {
                let sizes = Sizer.sizes(cached)
                items.append(CleanupItem(
                    id: "cache:\(folder)-cached", category: .caches, group: "Editors", title: "\(name) caches",
                    detail: "Rebuilt on next launch. Quit \(name) before cleaning.",
                    path: support, size: sizes.values.reduce(0, +), risk: .safe, selectedByDefault: false,
                    action: .delete(cached)
                ))
            }
        }
        return items
    }
}
