import Foundation

/// Language versions installed through version managers that none of your
/// projects ask for. The newest version per language and manager always
/// stays, unless your shell uses another manager for that language.
public struct ToolchainScanner: Scanner {
    public let category: Category = .toolchains

    public init() {}

    struct Install {
        var manager: String
        var language: String
        var version: String
        var path: String
        var uninstall: Command?
    }

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let roots = context.settings.projectRoots.map { expandTilde($0, home: context.home) }
        let usage = VersionUsage.collect(home: context.home, roots: roots)
        let installs = findInstalls(context)
        let active = activeManagers(context, languages: Set(installs.map(\.language)))

        var keep = Set<String>()  // paths of the newest per (manager, language)
        let grouped = Dictionary(grouping: installs) { "\($0.manager)|\($0.language)" }
        for (_, list) in grouped {
            if let newest = list.max(by: { Self.compareVersions($0.version, $1.version) == .orderedAscending }) {
                keep.insert(newest.path)
            }
        }
        let managersPerLanguage = Dictionary(grouping: installs, by: \.language).mapValues { Set($0.map(\.manager)) }

        // Every installed version is listed, so you see what is on disk. Only
        // the ones nothing needs are worded as candidates; none is preselected.
        var listed: [(Install, String, String)] = []  // install, status, detail
        for install in installs {
            let lang = Self.displayName(install.language)
            let managers = managersPerLanguage[install.language] ?? []
            let shellUses = active[install.language]
            // Only a duplicate when the shell demonstrably uses one of the
            // other managers that has this language installed.
            let duplicate = managers.count > 1 && shellUses != nil && shellUses != install.manager
                && managers.contains(shellUses!)
            let used = usage.isUsed(language: install.language, version: install.version)
            let isDefault = (install.manager == "rustup" && Self.isDefaultRustup(install, context: context))
                || (install.manager == "sdkman" && Self.isSdkmanCurrent(install))

            let status: String
            var detail = install.manager
            if duplicate, let shellUses {
                status = "unused duplicate"
                detail += " · your shell uses \(shellUses) for \(lang), not this one"
            } else if used {
                status = "in use"
                detail += " · a version file in your projects or your global config asks for it"
            } else if isDefault {
                status = "default"
                detail += " · the default toolchain"
            } else if keep.contains(install.path) {
                status = "newest"
                detail += " · the newest \(lang) in \(install.manager), kept as fallback"
            } else {
                status = "not used"
                let projects = usage.projectCount[VersionUsage.normalizeLanguage(install.language)] ?? 0
                detail += projects > 0 ? " · none of your \(projects) \(lang) projects ask for it" : " · no project asks for it"
            }
            listed.append((install, status, detail))
        }

        let sizes = Sizer.sizes(listed.map(\.0.path))
        var items = listed.map { install, status, detail in
            CleanupItem(
                id: "toolchain:\(install.path)", category: .toolchains, group: Self.displayName(install.language),
                title: "\(Self.displayName(install.language)) \(install.version) · \(status)", detail: detail, path: install.path,
                size: sizes[install.path] ?? 0, risk: .careful, selectedByDefault: false,
                action: install.uninstall.map { .commands([$0], fallbackDelete: [install.path]) } ?? .delete([install.path])
            )
        }
        items += corepackVersions(context)
        items += homebrewDuplicates(context)
        return (items, [])
    }

    // MARK: - Finding installs

    private func findInstalls(_ context: ScanContext) -> [Install] {
        let h = context.home
        var result: [Install] = []

        func versions(_ dir: String) -> [String] {
            FileSystem.children(of: dir).filter { name in
                guard !name.hasPrefix("."), name != "current", name != "system" else { return false }
                let path = "\(dir)/\(name)"
                let link = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                return !link && FileSystem.isDirectory(path)
            }
        }

        // asdf and mise: <root>/<tool>/<version>
        let asdfRoot = (ProcessInfo.processInfo.environment["ASDF_DATA_DIR"] ?? "\(h)/.asdf") + "/installs"
        for tool in versions(asdfRoot) {
            for v in versions("\(asdfRoot)/\(tool)") {
                result.append(Install(manager: "asdf", language: VersionUsage.normalizeLanguage(tool), version: v,
                                      path: "\(asdfRoot)/\(tool)/\(v)", uninstall: Command("asdf", ["uninstall", tool, v])))
            }
        }
        let miseRoot = "\(h)/.local/share/mise/installs"
        for tool in versions(miseRoot) {
            for v in versions("\(miseRoot)/\(tool)") {
                result.append(Install(manager: "mise", language: VersionUsage.normalizeLanguage(tool), version: v,
                                      path: "\(miseRoot)/\(tool)/\(v)", uninstall: Command("mise", ["uninstall", "\(tool)@\(v)"])))
            }
        }

        // Single-language managers: (manager, language, folder, uninstall)
        let simple: [(String, String, String, ((String) -> Command)?)] = [
            ("nvm", "node", "\(h)/.nvm/versions/node", nil),
            ("fnm", "node", "\(h)/Library/Application Support/fnm/node-versions", { Command("fnm", ["uninstall", $0]) }),
            ("fnm", "node", "\(h)/.local/share/fnm/node-versions", { Command("fnm", ["uninstall", $0]) }),
            ("volta", "node", "\(h)/.volta/tools/image/node", nil),
            ("nodenv", "node", "\(h)/.nodenv/versions", { Command("nodenv", ["uninstall", "-f", $0]) }),
            ("pnpm env", "node", "\(h)/Library/pnpm/nodejs", { Command("pnpm", ["env", "remove", "--global", $0]) }),
            ("rbenv", "ruby", "\(h)/.rbenv/versions", { Command("rbenv", ["uninstall", "-f", $0]) }),
            ("rvm", "ruby", "\(h)/.rvm/rubies", nil),
            ("chruby", "ruby", "\(h)/.rubies", nil),
            ("pyenv", "python", "\(h)/.pyenv/versions", { Command("pyenv", ["uninstall", "-f", $0]) }),
            ("goenv", "go", "\(h)/.goenv/versions", { Command("goenv", ["uninstall", "-f", $0]) }),
            ("fvm", "flutter", "\(h)/fvm/versions", nil),
            ("tfenv", "terraform", "\(h)/.tfenv/versions", { Command("tfenv", ["uninstall", $0]) }),
            ("phpenv", "php", "\(h)/.phpenv/versions", nil),
        ]
        for (manager, lang, dir, uninstall) in simple {
            for name in versions(dir) {
                let version = VersionUsage.normalizeVersion(name)
                result.append(Install(manager: manager, language: lang, version: version, path: "\(dir)/\(name)",
                                      uninstall: uninstall?(name)))
            }
        }

        // uv: cpython-3.12.1-macos-aarch64-none
        let uvDir = "\(h)/.local/share/uv/python"
        for name in versions(uvDir) where name.hasPrefix("cpython-") || name.hasPrefix("pypy-") {
            let version = name.split(separator: "-").dropFirst().first.map(String.init) ?? name
            result.append(Install(manager: "uv", language: "python", version: version, path: "\(uvDir)/\(name)", uninstall: nil))
        }

        // rustup: stable-aarch64-apple-darwin, 1.75.0-aarch64-apple-darwin
        let rustup = (ProcessInfo.processInfo.environment["RUSTUP_HOME"] ?? "\(h)/.rustup") + "/toolchains"
        for name in versions(rustup) {
            let version = name.replacingOccurrences(of: #"-(aarch64|x86_64)-apple-darwin$"#, with: "", options: .regularExpression)
            result.append(Install(manager: "rustup", language: "rust", version: version, path: "\(rustup)/\(name)",
                                  uninstall: Command("rustup", ["toolchain", "uninstall", name])))
        }

        // SDKMAN: candidates/<candidate>/<version>
        let sdkman = "\(h)/.sdkman/candidates"
        for candidate in versions(sdkman) {
            for v in versions("\(sdkman)/\(candidate)") {
                result.append(Install(manager: "sdkman", language: VersionUsage.normalizeLanguage(candidate), version: v,
                                      path: "\(sdkman)/\(candidate)/\(v)", uninstall: nil))
            }
        }

        // Extra Swift toolchains
        let toolchains = "\(h)/Library/Developer/Toolchains"
        for name in FileSystem.children(of: toolchains) where name.hasSuffix(".xctoolchain") {
            let version = name.replacingOccurrences(of: ".xctoolchain", with: "").replacingOccurrences(of: "swift-", with: "")
            result.append(Install(manager: "toolchain", language: "swift", version: version, path: "\(toolchains)/\(name)", uninstall: nil))
        }
        return result
    }

    // MARK: - Which manager the shell uses

    static let binaries: [String: String] = [
        "node": "node", "ruby": "ruby", "python": "python3", "rust": "rustc", "go": "go", "java": "java",
        "elixir": "elixir", "erlang": "erl", "php": "php", "terraform": "terraform", "flutter": "flutter"
    ]

    private func activeManagers(_ context: ScanContext, languages: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for lang in languages {
            guard let bin = Self.binaries[lang], let path = context.shell.resolver.path(for: bin) else { continue }
            let p = path
            let manager: String?
            switch true {
            case p.contains("/.asdf/"): manager = "asdf"
            case p.contains("/mise/"): manager = "mise"
            case p.contains("/.cargo/bin/") || p.contains("/.rustup/"): manager = "rustup"
            case p.contains("/.nvm/"): manager = "nvm"
            case p.contains("/fnm"): manager = "fnm"
            case p.contains("/.volta/"): manager = "volta"
            case p.contains("/.nodenv/"): manager = "nodenv"
            case p.contains("/.rbenv/"): manager = "rbenv"
            case p.contains("/.rvm/"): manager = "rvm"
            case p.contains("/.pyenv/"): manager = "pyenv"
            case p.contains("/.goenv/"): manager = "goenv"
            case p.contains("/.sdkman/"): manager = "sdkman"
            case p.contains("/fvm/"): manager = "fvm"
            case p.contains("/.tfenv/"): manager = "tfenv"
            case p.contains("/homebrew/") || p.hasPrefix("/opt/homebrew/") || p.hasPrefix("/usr/local/"): manager = "Homebrew"
            default: manager = nil
            }
            if let manager { result[lang] = manager }
        }
        return result
    }

    static func isDefaultRustup(_ install: Install, context: ScanContext) -> Bool {
        let settings = FileSystem.readText((ProcessInfo.processInfo.environment["RUSTUP_HOME"] ?? "\(context.home)/.rustup") + "/settings.toml") ?? ""
        guard let line = settings.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("default_toolchain") }),
              let value = line.split(separator: "\"").dropFirst().first else { return false }
        return (install.path as NSString).lastPathComponent.hasPrefix(String(value))
    }

    static func isSdkmanCurrent(_ install: Install) -> Bool {
        let current = ((install.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("current")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return false }
        return (target as NSString).lastPathComponent == (install.path as NSString).lastPathComponent
    }

    // MARK: - Package manager versions

    /// Corepack keeps every pnpm, Yarn and npm version a project ever asked
    /// for. The newest of each stays; older ones download again on demand.
    private func corepackVersions(_ context: ScanContext) -> [CleanupItem] {
        var items: [CleanupItem] = []
        for base in [".cache/node/corepack/v1", ".cache/node/corepack"].map(context.path) {
            for manager in ["pnpm", "yarn", "npm"] {
                let dir = "\(base)/\(manager)"
                let versions = FileSystem.subdirectories(of: dir).filter { $0.first?.isNumber == true }
                    .sorted { Self.compareVersions($0, $1) == .orderedDescending }
                guard !versions.isEmpty else { continue }
                let sizes = Sizer.sizes(versions.map { "\(dir)/\($0)" })
                for (index, version) in versions.enumerated() {
                    let path = "\(dir)/\(version)"
                    let newest = index == 0
                    items.append(CleanupItem(
                        id: "corepack:\(path)", category: .toolchains, group: "Package managers",
                        title: "\(manager) \(version) · \(newest ? "newest" : "older")",
                        detail: "Corepack · " + (newest ? "the newest \(manager) Corepack has" : "downloaded again if a project asks for it"),
                        path: path, size: sizes[path] ?? 0, risk: .rebuild, selectedByDefault: !newest, action: .delete([path])
                    ))
                }
            }
        }
        return items
    }

    // MARK: - Homebrew

    /// Several versions of the same formula (openssl@3, openssl@3.2) where
    /// nothing installed depends on the older one.
    private func homebrewDuplicates(_ context: ScanContext) -> [CleanupItem] {
        guard context.shell.has("brew") else { return [] }
        let list = context.shell.run("brew", ["list", "--formula", "-1"], timeout: 60)
        guard list.succeeded else { return [] }
        let formulas = list.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let groups = Dictionary(grouping: formulas) { $0.components(separatedBy: "@").first ?? $0 }
            .filter { $0.value.count > 1 }
        guard !groups.isEmpty else { return [] }

        let prefix = context.shell.run("brew", ["--prefix"], timeout: 30).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        for (_, members) in groups {
            let sorted = members.sorted { Self.compareVersions(Self.formulaVersion($0), Self.formulaVersion($1)) == .orderedDescending }
            for formula in sorted.dropFirst() {
                let uses = context.shell.run("brew", ["uses", "--installed", formula], timeout: 60)
                if uses.succeeded, uses.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidates.append(formula)
                }
            }
        }
        let paths = candidates.map { "\(prefix)/Cellar/\($0)" }
        let sizes = Sizer.sizes(paths)
        return zip(candidates, paths).map { formula, path in
            let base = formula.components(separatedBy: "@").first ?? formula
            let others = (groups[base] ?? []).filter { $0 != formula }.sorted().joined(separator: ", ")
            return CleanupItem(
                id: "brew:\(formula)", category: .toolchains, group: "Homebrew", title: formula,
                detail: "Also installed: \(others) · nothing installed depends on \(formula)",
                path: path, size: sizes[path] ?? 0, risk: .careful, selectedByDefault: false,
                action: .commands([Command("brew", ["uninstall", formula])], fallbackDelete: [])
            )
        }
    }

    static func formulaVersion(_ formula: String) -> String {
        formula.contains("@") ? (formula.components(separatedBy: "@").last ?? "0") : "9999"
    }

    // MARK: - Helpers

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    static func displayName(_ language: String) -> String {
        switch language {
        case "node": return "Node"
        case "python": return "Python"
        case "ruby": return "Ruby"
        case "rust": return "Rust"
        case "go": return "Go"
        case "java": return "Java"
        case "php": return "PHP"
        case "erlang": return "Erlang"
        case "elixir": return "Elixir"
        case "flutter": return "Flutter"
        case "terraform": return "Terraform"
        case "swift": return "Swift"
        default: return language.prefix(1).uppercased() + language.dropFirst()
        }
    }
}
