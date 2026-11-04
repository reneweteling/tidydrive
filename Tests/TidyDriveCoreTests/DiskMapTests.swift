import XCTest
@testable import TidyDriveCore

final class DiskMapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diskmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, kb: Int) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: kb * 1024).write(to: url)
    }

    private func scan(min: Int64 = 500_000) async -> DiskNode {
        await DiskMapScanner.scan(root: root.path, minNodeSize: min, progress: { _ in })
    }

    func testSizesRollUp() async throws {
        try write("a/big1.bin", kb: 1024)
        try write("a/b/big2.bin", kb: 2048)
        try write("top.bin", kb: 1024)
        let tree = await scan()
        XCTAssertEqual(tree.size, FileSystem.allocatedSize(of: root))
        let a = try XCTUnwrap(tree.children.first { $0.name == "a" })
        XCTAssertEqual(a.size, FileSystem.allocatedSize(of: root.appendingPathComponent("a")))
        XCTAssertTrue(a.isDirectory)
        XCTAssertNotNil(a.children.first { $0.name == "b" })
        XCTAssertEqual(tree.children.first?.name, "a")
    }

    func testSmallItemsAreFolded() async throws {
        try write("big.bin", kb: 1024)
        try write("s1.txt", kb: 4)
        try write("s2.txt", kb: 4)
        try write("tiny/x.txt", kb: 4)
        let tree = await scan()
        XCTAssertEqual(tree.children.count, 2)
        let small = try XCTUnwrap(tree.children.first { $0.isSynthetic })
        XCTAssertEqual(small.name, "Smaller items")
        XCTAssertEqual(small.itemCount, 3)
        XCTAssertEqual(tree.size, FileSystem.allocatedSize(of: root))
    }

    func testPackagesAreLeaves() async throws {
        try write("Thing.app/Contents/big.bin", kb: 1024)
        try write("Thing.app/Contents/Resources/more.bin", kb: 1024)
        let tree = await scan()
        let app = try XCTUnwrap(tree.children.first { $0.name == "Thing.app" })
        XCTAssertTrue(app.isPackage)
        XCTAssertTrue(app.children.isEmpty)
        XCTAssertEqual(app.size, FileSystem.allocatedSize(of: root.appendingPathComponent("Thing.app")))
    }

    func testRemoveSubtractsFromAncestors() async throws {
        try write("a/big1.bin", kb: 1024)
        try write("a/big2.bin", kb: 1024)
        let tree = await scan()
        let a = try XCTUnwrap(tree.children.first { $0.name == "a" })
        let victim = try XCTUnwrap(a.children.first)
        let before = tree.size
        a.remove(victim)
        XCTAssertEqual(tree.size, before - victim.size)
        XCTAssertEqual(a.children.count, 1)
    }

    func testSymlinksAreNotFollowed() async throws {
        try write("real/big.bin", kb: 1024)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: root.appendingPathComponent("real"))
        let tree = await scan()
        XCTAssertEqual(tree.size, FileSystem.allocatedSize(of: root.appendingPathComponent("real")))
    }
}

extension DiskMapTests {
    /// Run with DISKMAP_TIMING=1 swift test --filter DiskMapTests/testTimeLibrary
    func testTimeLibrary() async throws {
        guard ProcessInfo.processInfo.environment["DISKMAP_TIMING"] != nil else { throw XCTSkip("timing only") }
        let path = NSHomeDirectory() + "/Library"
        let start = Date()
        let tree = await DiskMapScanner.scan(root: path, progress: { _ in })
        print("DISKMAP \(ByteFormat.string(tree.size)) in \(Date().timeIntervalSince(start))s")
    }
}
