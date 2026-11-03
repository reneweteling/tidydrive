import Foundation

/// A global cache. When the tool is installed its own clean command runs,
/// so its bookkeeping stays right; otherwise the folders are removed.
public struct CacheRule: Sendable {
    public var id: String
    public var group: String
    public var name: String
    /// Relative to the home folder.
    public var paths: [String]
    public var command: Command?
    public var risk: Risk
    public var selected: Bool
    public var note: String?

    public init(_ id: String, group: String, name: String, paths: [String], command: Command? = nil,
                risk: Risk = .safe, selected: Bool = true, note: String? = nil) {
        self.id = id
        self.group = group
        self.name = name
        self.paths = paths
        self.command = command
        self.risk = risk
        self.selected = selected
        self.note = note
    }
}

public enum CacheRules {
    public static let all: [CacheRule] = [
        // JavaScript
        CacheRule("npm", group: "JavaScript", name: "npm cache", paths: [".npm/_cacache"],
                  command: Command("npm", ["cache", "clean", "--force"])),
        CacheRule("pnpm", group: "JavaScript", name: "pnpm store", paths: ["Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store"],
                  command: Command("pnpm", ["store", "prune"]),
                  note: "pnpm store prune removes packages no project links to"),
        CacheRule("yarn", group: "JavaScript", name: "Yarn cache", paths: ["Library/Caches/Yarn", ".yarn/berry/cache"],
                  command: Command("yarn", ["cache", "clean"])),
        CacheRule("bun", group: "JavaScript", name: "Bun cache", paths: [".bun/install/cache"],
                  command: Command("bun", ["pm", "cache", "rm"])),
        CacheRule("deno", group: "JavaScript", name: "Deno cache", paths: ["Library/Caches/deno"]),
        CacheRule("node-gyp", group: "JavaScript", name: "node-gyp headers", paths: ["Library/Caches/node-gyp", ".node-gyp"]),
        CacheRule("electron", group: "JavaScript", name: "Electron downloads", paths: ["Library/Caches/electron", "Library/Caches/electron-builder"]),
        CacheRule("corepack", group: "JavaScript", name: "Corepack", paths: [".cache/node/corepack"]),
        CacheRule("prisma", group: "JavaScript", name: "Prisma engines", paths: [".cache/prisma"]),
        CacheRule("turbo", group: "JavaScript", name: "Turborepo cache", paths: ["Library/Caches/turbo"]),

        // Python
        CacheRule("pip", group: "Python", name: "pip cache", paths: ["Library/Caches/pip"],
                  command: Command("pip3", ["cache", "purge"])),
        CacheRule("uv", group: "Python", name: "uv cache", paths: [".cache/uv"],
                  command: Command("uv", ["cache", "clean"])),
        CacheRule("poetry", group: "Python", name: "Poetry cache", paths: ["Library/Caches/pypoetry"]),
        CacheRule("conda-pkgs", group: "Python", name: "conda packages", paths: ["miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs"],
                  command: Command("conda", ["clean", "--all", "--yes"])),

        // Rust
        CacheRule("cargo", group: "Rust", name: "Cargo registry", paths: [".cargo/registry/cache", ".cargo/registry/src", ".cargo/git/checkouts"]),
        CacheRule("sccache", group: "Rust", name: "sccache", paths: ["Library/Caches/Mozilla.sccache"]),

        // Go
        CacheRule("go-mod", group: "Go", name: "Go module cache", paths: ["go/pkg/mod"],
                  command: Command("go", ["clean", "-modcache"])),
        CacheRule("go-build", group: "Go", name: "Go build cache", paths: ["Library/Caches/go-build"],
                  command: Command("go", ["clean", "-cache"])),

        // Elixir, Erlang
        CacheRule("hex", group: "Elixir, Erlang", name: "Hex packages", paths: [".hex/packages", ".cache/hex"]),
        CacheRule("rebar3", group: "Elixir, Erlang", name: "rebar3 cache", paths: [".cache/rebar3"]),

        // Ruby
        CacheRule("bundler", group: "Ruby", name: "Bundler cache", paths: [".bundle/cache"]),

        // JVM
        CacheRule("gradle", group: "JVM", name: "Gradle caches", paths: [".gradle/caches"], risk: .rebuild),
        CacheRule("gradle-wrapper", group: "JVM", name: "Gradle wrapper downloads", paths: [".gradle/wrapper/dists"], risk: .rebuild),
        CacheRule("maven", group: "JVM", name: "Maven repository", paths: [".m2/repository"], risk: .rebuild),
        CacheRule("coursier", group: "JVM", name: "Coursier and Ivy", paths: ["Library/Caches/Coursier", ".ivy2/cache"], risk: .rebuild),

        // Apple
        CacheRule("homebrew", group: "Apple", name: "Homebrew downloads", paths: ["Library/Caches/Homebrew"],
                  command: Command("brew", ["cleanup", "--prune=all"])),
        CacheRule("cocoapods", group: "Apple", name: "CocoaPods cache", paths: ["Library/Caches/CocoaPods"]),
        CacheRule("carthage", group: "Apple", name: "Carthage cache", paths: ["Library/Caches/org.carthage.CarthageKit"]),
        CacheRule("swiftpm", group: "Apple", name: "SwiftPM cache", paths: ["Library/Caches/org.swift.swiftpm"]),

        // Others
        CacheRule("pub", group: "Dart, Flutter", name: "pub cache", paths: [".pub-cache"],
                  command: Command("dart", ["pub", "cache", "clean", "--force"]), risk: .rebuild),
        CacheRule("composer", group: "PHP", name: "Composer cache", paths: ["Library/Caches/composer", ".composer/cache"],
                  command: Command("composer", ["clear-cache"])),
        CacheRule("nuget", group: ".NET", name: "NuGet packages", paths: [".nuget/packages"],
                  command: Command("dotnet", ["nuget", "locals", "all", "--clear"]), risk: .rebuild),
        CacheRule("haskell", group: "Haskell", name: "Stack and Cabal", paths: [".stack/pantry", ".cabal/packages"], risk: .rebuild),
        CacheRule("puppeteer", group: "Testing", name: "Puppeteer browsers", paths: [".cache/puppeteer"], risk: .rebuild),
        CacheRule("cypress", group: "Testing", name: "Cypress binaries", paths: ["Library/Caches/Cypress"],
                  command: Command("cypress", ["cache", "prune"]), risk: .rebuild),
        CacheRule("pre-commit", group: "Other", name: "pre-commit environments", paths: [".cache/pre-commit"],
                  command: Command("pre-commit", ["clean"])),
        CacheRule("bazel", group: "Other", name: "Bazel output", paths: [".cache/bazel"], risk: .rebuild),
        CacheRule("ccache", group: "Other", name: "ccache", paths: ["Library/Caches/ccache"],
                  command: Command("ccache", ["-C"])),
        CacheRule("vagrant", group: "Other", name: "Vagrant boxes", paths: [".vagrant.d/boxes"], risk: .careful, selected: false),
        CacheRule("terraform", group: "Other", name: "Terraform plugin cache", paths: [".terraform.d/plugin-cache"]),
    ]
}
