import Foundation

/// Which language versions your projects ask for, read from their version
/// files (.tool-versions, .nvmrc, .ruby-version...) and the global config.
public struct VersionUsage: Sendable {
    /// language -> requested specs ("20", "3.2.2", "stable").
    public private(set) var specs: [String: Set<String>] = [:]
    /// language -> number of projects that request something.
    public private(set) var projectCount: [String: Int] = [:]

    public init() {}

    public mutating func add(language: String, spec: String) {
        let lang = Self.normalizeLanguage(language)
        let s = Self.normalizeVersion(spec)
        guard !s.isEmpty else { return }
        specs[lang, default: []].insert(s)
    }

    /// True when some spec points at this installed version.
    public func isUsed(language: String, version: String) -> Bool {
        let v = Self.normalizeVersion(version)
        for s in specs[Self.normalizeLanguage(language)] ?? [] {
            if v == s || v.hasPrefix(s + ".") || v.hasPrefix(s + "-") { return true }
            // rustup names toolchains "stable-aarch64-apple-darwin".
            if v.hasPrefix(s + "-") { return true }
        }
        return false
    }

    public static func normalizeLanguage(_ raw: String) -> String {
        switch raw.lowercased() {
        case "nodejs", "node": return "node"
        case "golang", "go": return "go"
        case "python", "python3": return "python"
        case "rust", "rustc": return "rust"
        case "java", "openjdk": return "java"
        case "erl", "erlang": return "erlang"
        default: return raw.lowercased()
        }
    }

    public static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ruby-", "python-", "node-", "go", "v"] where s.hasPrefix(prefix) {
            let rest = s.dropFirst(prefix.count)
            if rest.first?.isNumber == true { s = String(rest) }
        }
        return s
    }

    // MARK: - Reading version files

    static let versionFiles: [String: String] = [
        ".nvmrc": "node", ".node-version": "node", ".ruby-version": "ruby", ".python-version": "python",
        ".java-version": "java", ".go-version": "go", ".terraform-version": "terraform", ".swift-version": "swift",
        ".php-version": "php"
    ]

    /// Reads one directory's version files.
    public mutating func read(directory dir: String) -> Bool {
        var found = false
        if let text = FileSystem.readText("\(dir)/.tool-versions") {
            found = true
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
                for version in parts.dropFirst() where !version.hasPrefix("#") { add(language: parts[0], spec: version) }
            }
        }
        for name in ["mise.toml", ".mise.toml", ".config/mise.toml", ".config/mise/config.toml", ".rtx.toml"] {
            guard let text = FileSystem.readText("\(dir)/\(name)") else { continue }
            found = true
            var inTools = false
            for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("[") { inTools = line == "[tools]"; continue }
                guard inTools, let eq = line.firstIndex(of: "=") else { continue }
                let tool = line[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                let value = line[line.index(after: eq)...]
                // node = "20" or node = ["20", "18"] or node = { version = "20" }
                for match in value.split(separator: "\"").enumerated() where match.offset % 2 == 1 {
                    let v = String(match.element)
                    if v.first?.isNumber == true || ["stable", "nightly", "latest", "lts"].contains(v) {
                        add(language: tool.components(separatedBy: ":").last ?? tool, spec: v)
                    }
                }
            }
        }
        for (file, lang) in Self.versionFiles {
            guard let text = FileSystem.readText("\(dir)/\(file)") else { continue }
            found = true
            for line in text.split(whereSeparator: \.isNewline) {
                let v = line.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty, !v.hasPrefix("#") { add(language: lang, spec: v) }
            }
        }
        for file in ["rust-toolchain.toml", "rust-toolchain"] {
            guard let text = FileSystem.readText("\(dir)/\(file)") else { continue }
            found = true
            if file.hasSuffix(".toml") {
                if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("channel") }),
                   let value = line.split(separator: "\"").dropFirst().first {
                    add(language: "rust", spec: String(value))
                }
            } else {
                add(language: "rust", spec: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let text = FileSystem.readText("\(dir)/.fvmrc"),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let v = (json["flutter"] ?? json["flutterSdkVersion"]) as? String {
            found = true
            add(language: "flutter", spec: v)
        }
        if let text = FileSystem.readText("\(dir)/.sdkmanrc") {
            found = true
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].hasPrefix("#") { add(language: parts[0], spec: parts[1]) }
            }
        }
        return found
    }

    /// Reads the global config and every project under `roots`, a few levels deep.
    public static func collect(home: String, roots: [String]) -> VersionUsage {
        var usage = VersionUsage()
        _ = usage.read(directory: home)
        _ = usage.read(directory: "\(home)/.config/mise")
        if let text = FileSystem.readText("\(home)/.config/mise/config.toml") { _ = text }

        for root in roots {
            visit(root, depth: 0, usage: &usage)
        }
        return usage
    }

    private static func visit(_ dir: String, depth: Int, usage: inout VersionUsage) {
        let before = usage.specs
        if usage.read(directory: dir), depth > 0 {
            for lang in usage.specs.keys where usage.specs[lang] != before[lang] || before[lang] == nil {
                usage.projectCount[lang, default: 0] += 1
            }
        }
        guard depth < 4 else { return }
        for child in FileSystem.subdirectories(of: dir) {
            if child.hasPrefix(".") || ProjectRules.skipWhileWalking.contains(child) { continue }
            visit("\(dir)/\(child)", depth: depth + 1, usage: &usage)
        }
    }
}
