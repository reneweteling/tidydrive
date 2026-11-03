import Foundation

/// A folder inside a project that can be regenerated, recognised by a marker
/// file next to it. `target/` next to `Cargo.toml` is Rust output; a lone
/// `target/` is left alone.
public struct ProjectRule: Sendable {
    public var ecosystem: String
    /// File or folder names that identify the ecosystem. A leading `*` means
    /// "ends with", e.g. `*.csproj`.
    public var markers: [String]
    /// Removable children. A trailing `*` means "starts with", a leading `*`
    /// means "ends with".
    public var artifacts: [String]

    public init(_ ecosystem: String, markers: [String], artifacts: [String]) {
        self.ecosystem = ecosystem
        self.markers = markers
        self.artifacts = artifacts
    }

    func matchesMarker(in names: Set<String>) -> Bool {
        markers.contains { marker in
            if marker.hasPrefix("*") {
                let suffix = String(marker.dropFirst())
                return names.contains { $0.hasSuffix(suffix) }
            }
            return names.contains(marker)
        }
    }

    /// Children of `names` that this rule may remove.
    func artifacts(in names: [String]) -> [String] {
        var found: [String] = []
        for pattern in artifacts {
            if pattern.contains("/") {
                // Nested path such as tmp/cache; checked by the caller.
                found.append(pattern)
            } else if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                found += names.filter { $0.hasPrefix(prefix) }
            } else if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                found += names.filter { $0.hasSuffix(suffix) }
            } else if names.contains(pattern) {
                found.append(pattern)
            }
        }
        return found
    }
}

public enum ProjectRules {
    public static let all: [ProjectRule] = [
        ProjectRule("JavaScript", markers: ["package.json"], artifacts: [
            "node_modules", ".next", ".nuxt", ".svelte-kit", ".astro", ".turbo", ".parcel-cache", ".vite",
            ".angular/cache", ".expo", ".vercel/output", "storybook-static", ".docusaurus", ".output",
            "dist", "out", "coverage"
        ]),
        ProjectRule("Rust", markers: ["Cargo.toml"], artifacts: ["target"]),
        ProjectRule("Elixir", markers: ["mix.exs"], artifacts: ["_build", "deps", ".elixir_ls", "cover"]),
        ProjectRule("Erlang", markers: ["rebar.config"], artifacts: ["_build"]),
        ProjectRule("Ruby", markers: ["Gemfile"], artifacts: [
            "vendor/bundle", "tmp/cache", "coverage", "public/packs", "public/packs-test", "public/assets"
        ]),
        ProjectRule("Python", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], artifacts: [
            ".venv", "venv", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", "*.egg-info", "htmlcov"
        ]),
        ProjectRule("Swift", markers: ["Package.swift"], artifacts: [".build"]),
        ProjectRule("CocoaPods", markers: ["Podfile"], artifacts: ["Pods"]),
        ProjectRule("Carthage", markers: ["Cartfile"], artifacts: ["Carthage/Build"]),
        ProjectRule("Xcode", markers: ["*.xcodeproj", "*.xcworkspace"], artifacts: ["DerivedData", "build"]),
        ProjectRule("Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                    artifacts: ["build", ".gradle", ".kotlin", ".cxx"]),
        ProjectRule("Maven", markers: ["pom.xml"], artifacts: ["target"]),
        ProjectRule("Flutter", markers: ["pubspec.yaml"], artifacts: ["build", ".dart_tool"]),
        ProjectRule("Go", markers: ["go.mod"], artifacts: ["vendor"]),
        ProjectRule("PHP", markers: ["composer.json"], artifacts: ["vendor", "var/cache", "storage/framework/cache"]),
        ProjectRule(".NET", markers: ["*.csproj", "*.fsproj", "*.sln"], artifacts: ["bin", "obj"]),
        ProjectRule("Scala", markers: ["build.sbt"], artifacts: ["target", ".bloop", ".metals", ".bsp"]),
        ProjectRule("Haskell", markers: ["stack.yaml", "*.cabal", "cabal.project"], artifacts: [".stack-work", "dist-newstyle"]),
        ProjectRule("Zig", markers: ["build.zig"], artifacts: [".zig-cache", "zig-cache", "zig-out"]),
        ProjectRule("C/C++", markers: ["CMakeLists.txt"], artifacts: ["cmake-build-*", "build"]),
        ProjectRule("Elm", markers: ["elm.json"], artifacts: ["elm-stuff"]),
        ProjectRule("Terraform", markers: ["*.tf"], artifacts: [".terraform"]),
        ProjectRule("Bazel", markers: ["WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"], artifacts: ["bazel-*"]),
        ProjectRule("Unity", markers: ["ProjectSettings"], artifacts: ["Library", "Temp", "Obj", "Logs"]),
        ProjectRule("Godot", markers: ["project.godot"], artifacts: [".godot"]),
    ]

    /// Folder names never descended into while looking for projects.
    public static let skipWhileWalking: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".Trash", "Library", "Pods", "vendor", "target", ".build",
        "DerivedData", ".venv", "venv", "_build", "deps", ".next", ".gradle", "build", "dist", ".terraform",
        ".cache", ".idea", ".vscode",
        // Data, not code. Projects do not live in here, and they can hold
        // hundreds of thousands of files.
        "storage", "logs", "log", "uploads", "media", "fixtures", "tmp", "public", "assets", "static",
        "data", "coverage", "Carthage", "bower_components", "jspm_packages", "site-packages", "__pycache__"
    ]
}
