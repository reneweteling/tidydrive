import XCTest
@testable import TidyDriveCore

final class SafetyGuardTests: XCTestCase {
    let guardrail = SafetyGuard(home: "/Users/dev", projectRoots: ["/Users/dev/projects"])

    func testAllowsCachesAndBuildOutput() {
        XCTAssertEqual(guardrail.check("/Users/dev/projects/shop/node_modules"), .allowed)
        XCTAssertEqual(guardrail.check("/Users/dev/Library/Developer/Xcode/DerivedData"), .allowed)
        XCTAssertEqual(guardrail.check("/Users/dev/.npm/_cacache"), .allowed)
    }

    func testRefusesHomeAndPersonalFolders() {
        XCTAssertNotEqual(guardrail.check("/Users/dev"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/Documents"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/Library"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/Library/Mobile Documents/com~apple~CloudDocs"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/.ssh"), .allowed)
    }

    func testRefusesProjectRootsAndTheirParents() {
        XCTAssertNotEqual(guardrail.check("/Users/dev/projects"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/projects/"), .allowed)
    }

    func testRefusesOutsideHomeAndTraversal() {
        XCTAssertNotEqual(guardrail.check("/System/Library"), .allowed)
        XCTAssertNotEqual(guardrail.check("relative/path"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/dev/projects/shop/../../Documents"), .allowed)
        XCTAssertNotEqual(guardrail.check("/Users/devil/projects/x/node_modules"), .allowed)
    }

    func testXcodeAppsOnlyToTrash() {
        XCTAssertEqual(guardrail.check("/Applications/Xcode-16.4.app", forTrash: true), .allowed)
        XCTAssertNotEqual(guardrail.check("/Applications/Xcode-16.4.app", forTrash: false), .allowed)
        XCTAssertNotEqual(guardrail.check("/Applications/Safari.app", forTrash: true), .allowed)
    }
}

final class ThresholdAlarmTests: XCTestCase {
    func testFiresOnceAndRearmsBelowReset() {
        var alarm = ThresholdAlarm(threshold: 0.9, reset: 0.85)
        XCTAssertFalse(alarm.update(usedFraction: 0.80))
        XCTAssertTrue(alarm.update(usedFraction: 0.91))
        XCTAssertFalse(alarm.update(usedFraction: 0.93))
        XCTAssertFalse(alarm.update(usedFraction: 0.88), "hovering between reset and threshold stays quiet")
        XCTAssertFalse(alarm.update(usedFraction: 0.91))
        XCTAssertFalse(alarm.update(usedFraction: 0.84))
        XCTAssertTrue(alarm.update(usedFraction: 0.90))
    }
}

final class VersionUsageTests: XCTestCase {
    func testPrefixMatching() {
        var usage = VersionUsage()
        usage.add(language: "nodejs", spec: "v20")
        usage.add(language: "ruby", spec: "ruby-3.2.2")
        usage.add(language: "rust", spec: "stable")
        XCTAssertTrue(usage.isUsed(language: "node", version: "20.11.1"))
        XCTAssertTrue(usage.isUsed(language: "node", version: "v20.11.1"))
        XCTAssertFalse(usage.isUsed(language: "node", version: "18.20.4"))
        XCTAssertFalse(usage.isUsed(language: "node", version: "200.0.0"))
        XCTAssertTrue(usage.isUsed(language: "ruby", version: "3.2.2"))
        XCTAssertFalse(usage.isUsed(language: "ruby", version: "3.2.20"))
        XCTAssertTrue(usage.isUsed(language: "rust", version: "stable-aarch64-apple-darwin"))
    }

    func testReadsVersionFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "nodejs 22.1.0\npython 3.12.4 3.11.9\n# comment\n".write(to: dir.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        try "[tools]\nerlang = \"27.1\"\nnode = [\"20\", \"18\"]\n".write(to: dir.appendingPathComponent("mise.toml"), atomically: true, encoding: .utf8)
        try "[toolchain]\nchannel = \"1.80.0\"\n".write(to: dir.appendingPathComponent("rust-toolchain.toml"), atomically: true, encoding: .utf8)

        var usage = VersionUsage()
        XCTAssertTrue(usage.read(directory: dir.path))
        XCTAssertTrue(usage.isUsed(language: "node", version: "22.1.0"))
        XCTAssertTrue(usage.isUsed(language: "node", version: "18.19.0"))
        XCTAssertTrue(usage.isUsed(language: "python", version: "3.11.9"))
        XCTAssertTrue(usage.isUsed(language: "erlang", version: "27.1.2"))
        XCTAssertTrue(usage.isUsed(language: "rust", version: "1.80.0-aarch64-apple-darwin"))
        XCTAssertFalse(usage.isUsed(language: "python", version: "3.10.0"))
    }
}

final class DockerParsingTests: XCTestCase {
    func testDecimalSizes() {
        XCTAssertEqual(DockerScanner.parseSize("7.66GB"), 7_660_000_000)
        XCTAssertEqual(DockerScanner.parseSize("349.2MB"), 349_200_000)
        XCTAssertEqual(DockerScanner.parseSize("20.5kB"), 20_500)
        XCTAssertEqual(DockerScanner.parseSize("2B"), 2)
        XCTAssertEqual(DockerScanner.parseSize("1.2GB (50%)"), 1_200_000_000)
        XCTAssertEqual(DockerScanner.parseSize("N/A"), 0)
        XCTAssertEqual(DockerScanner.parseSize(nil), 0)
    }

    func testLabels() {
        let labels = DockerScanner.labels("com.docker.compose.project=shop,com.docker.volume.anonymous=,a=b=c")
        XCTAssertEqual(labels["com.docker.compose.project"], "shop")
        XCTAssertEqual(labels["com.docker.volume.anonymous"], "")
        XCTAssertEqual(labels["a"], "b=c")
    }
}

final class ProjectScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tidydrive-\(UUID().uuidString)")
        let fm = FileManager.default
        func file(_ path: String, _ bytes: Int = 10) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try file("shop/package.json")
        try file("shop/node_modules/left-pad/index.js", 50_000)
        try file("rusty/Cargo.toml")
        try file("rusty/target/debug/app", 80_000)
        try file("notes/target/plan.md", 5_000)              // target without Cargo.toml: keep
        try file("phoenix/mix.exs")
        try file("phoenix/_build/dev/lib.beam", 20_000)
        try file("phoenix/deps/plug/mix.exs", 20_000)
        try file("mono/packages/web/package.json")
        try file("mono/packages/web/.next/cache/x", 30_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsOnlyMarkedArtifacts() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let context = ScanContext(home: home, settings: ScanSettings(projectRoots: [root.path], categories: [.projects]),
                                  shell: Shell(resolver: ToolResolver()))
        let (items, _) = ProjectScanner().scan(context)
        let titles = Set(items.map(\.title))
        XCTAssertTrue(titles.contains("shop/node_modules"))
        XCTAssertTrue(titles.contains("rusty/target"))
        XCTAssertTrue(titles.contains("phoenix/_build"))
        XCTAssertTrue(titles.contains("phoenix/deps"))
        XCTAssertTrue(titles.contains("mono/packages/web/.next"))
        XCTAssertFalse(titles.contains("notes/target"), "a target folder without Cargo.toml is not build output")
        XCTAssertTrue(items.allSatisfy { $0.risk == .rebuild && $0.size > 0 })
    }

    func testRuleMatching() {
        let rust = ProjectRules.all.first { $0.ecosystem == "Rust" }!
        XCTAssertTrue(rust.matchesMarker(in: ["Cargo.toml", "src"]))
        XCTAssertFalse(rust.matchesMarker(in: ["package.json"]))
        let dotnet = ProjectRules.all.first { $0.ecosystem == ".NET" }!
        XCTAssertTrue(dotnet.matchesMarker(in: ["App.csproj"]))
        let cpp = ProjectRules.all.first { $0.ecosystem == "C/C++" }!
        XCTAssertEqual(Set(cpp.artifacts(in: ["cmake-build-debug", "cmake-build-release", "src"])),
                       ["cmake-build-debug", "cmake-build-release"])
    }
}

final class CleanupItemTests: XCTestCase {
    func testCarefulIsNeverPreselected() {
        let item = CleanupItem(id: "x", category: .docker, group: "g", title: "t", detail: "d", path: nil, size: 1,
                               risk: .careful, selectedByDefault: true, action: .delete([]))
        XCTAssertFalse(item.selectedByDefault)
    }
}

final class CleanerTests: XCTestCase {
    func testDeletesAllowedPathsAndRefusesOthers() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tidydrive-home-\(UUID().uuidString)")
        let target = home.appendingPathComponent("projects/shop/node_modules/pkg")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Read-only files, like Go's module cache.
        let file = target.appendingPathComponent("index.js")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { _ = Shell.execute(path: "/bin/chmod", arguments: ["-R", "u+w", home.path], timeout: 10); try? FileManager.default.removeItem(at: home) }

        let guardrail = SafetyGuard(home: home.path, projectRoots: [home.appendingPathComponent("projects").path])
        let cleaner = Cleaner(shell: Shell(resolver: ToolResolver()), guardrail: guardrail)
        let modules = home.appendingPathComponent("projects/shop/node_modules").path
        let ok = CleanupItem(id: "a", category: .projects, group: "", title: "", detail: "", path: modules, size: 1,
                             risk: .rebuild, selectedByDefault: true, action: .delete([modules]))
        let refused = CleanupItem(id: "b", category: .projects, group: "", title: "", detail: "", path: nil, size: 1,
                                  risk: .rebuild, selectedByDefault: true, action: .delete([home.appendingPathComponent("projects").path]))
        let report = await cleaner.clean([ok, refused])

        XCTAssertFalse(FileManager.default.fileExists(atPath: modules))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("projects").path))
        XCTAssertEqual(report.outcomes.map(\.succeeded), [true, false])
        XCTAssertTrue(report.outcomes[1].message?.contains("Refused") == true)
    }
}
