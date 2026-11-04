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

    func testKeptProjectsAreLeftAlone() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settings = ScanSettings(projectRoots: [root.path], categories: [.projects],
                                    keptProjects: [root.appendingPathComponent("rusty").path, root.appendingPathComponent("mono").path])
        let (items, notes) = ProjectScanner().scan(ScanContext(home: home, settings: settings, shell: Shell(resolver: ToolResolver())))
        let titles = Set(items.map(\.title))
        XCTAssertFalse(titles.contains("rusty/target"))
        XCTAssertFalse(titles.contains("mono/packages/web/.next"), "everything inside a kept project is left alone")
        XCTAssertTrue(titles.contains("shop/node_modules"))
        XCTAssertTrue(items.allSatisfy { $0.project != nil })
        XCTAssertTrue(notes.contains { $0.message.contains("2 kept projects") })
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

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

final class ConversionTests: XCTestCase {
    var dir: URL!
    var trash: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidydrive-media-\(UUID().uuidString)")
        trash = dir.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func cleaner() -> Cleaner {
        let trash = self.trash!
        return Cleaner(shell: Shell(resolver: ToolResolver()), guardrail: SafetyGuard(home: dir.path, projectRoots: []),
                       moveToTrash: { url in
                           let target = trash.appendingPathComponent(url.lastPathComponent)
                           try FileManager.default.moveItem(at: url, to: target)
                           return target
                       })
    }

    /// Two seconds of moving gradient, H.264 at a deliberately high bitrate.
    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<360 { for x in 0..<640 {
                let p = base + y * stride + x * 4
                p[0] = UInt8((x + frame * 4) % 256); p[1] = UInt8((y * 2 + frame) % 256); p[2] = UInt8((x ^ y) % 256); p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    func testVideoConvertsToMP4AndOriginalGoesToTrash() async throws {
        let movies = dir.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let source = movies.appendingPathComponent("clip.mov")
        try await makeVideo(source)
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let item = CleanupItem(id: "v", category: .videos, group: "", title: "clip.mov", detail: "", path: source.path,
                               size: 1, risk: .careful, selectedByDefault: false,
                               action: .convert(MediaConversion(kind: .video, source: source.path, originalSize: size, estimatedSize: 0)))
        let report = await cleaner().clean([item], videoQuality: .small)

        XCTAssertEqual(report.outcomes.first?.succeeded, true, report.outcomes.first?.message ?? "")
        let mp4 = movies.appendingPathComponent("clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the original left its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("clip.mov").path))
        let info = try await VideoEncoder.probe(mp4)
        XCTAssertEqual(info.codec.lowercased(), "hvc1")
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.duration, 2, accuracy: 0.2)
        XCTAssertEqual(report.trashedOriginals.count, 1)
    }

    func testPhotoConvertsToHEICKeepingSize() async throws {
        let pictures = dir.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let source = pictures.appendingPathComponent("shot.png")
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<60 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: i * 13, y: i * 9, width: 200, height: 150))
        }
        let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        let item = CleanupItem(id: "p", category: .photos, group: "", title: "shot.png", detail: "", path: source.path,
                               size: 1, risk: .careful, selectedByDefault: false,
                               action: .convert(MediaConversion(kind: .photo, source: source.path, originalSize: size, estimatedSize: 0)))
        let report = await cleaner().clean([item])
        let heic = pictures.appendingPathComponent("shot.heic")
        if report.outcomes.first?.succeeded == false {
            // A flat test image can already be tiny as PNG; then the original must stay.
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: heic.path))
        XCTAssertEqual(PhotoEncoder.probe(heic)?.width, 800)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}


final class TransparencyTests: XCTestCase {
    func testTransparentPNGKeepsItsAlphaAsHEIC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidydrive-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("logo.png"), heic = dir.appendingPathComponent("logo.heic")

        // Transparent canvas with an opaque red square in the middle.
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 400, height: 400))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        try PhotoEncoder.encode(source: png, output: heic)
        try PhotoEncoder.verify(original: png, converted: heic)
        XCTAssertTrue(PhotoEncoder.hasAlpha(heic), "HEIC lost the transparent layer")

        // The corner must still be see-through, the centre opaque.
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(heic as CFURL, nil)!, 0, nil)!
        let out = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        out.clear(CGRect(x: 0, y: 0, width: 400, height: 400))
        out.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let px = out.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(px[3], 10, "corner should be transparent")
        XCTAssertGreaterThan(px[(200 * 400 + 200) * 4 + 3], 245, "centre should be opaque")
    }
}
