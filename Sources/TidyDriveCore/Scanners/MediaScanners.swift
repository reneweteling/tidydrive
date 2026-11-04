import CryptoKit
import Foundation
import ImageIO
import Vision

extension ScanSettings {
    /// The configured media folders, or the defaults plus the project folders.
    func resolvedMediaFolders(home: String) -> [String] {
        let list = mediaFolders.isEmpty ? MediaLocator.defaultFolders(home: home) + projectRoots : mediaFolders
        var seen = Set<String>()
        return list.map { SafetyGuard.normalize(expandTilde($0, home: home)) }.filter { seen.insert($0).inserted }
    }
}

/// Large videos that shrink a lot as H.265 MP4. The size of each item is the
/// expected saving, so category totals read as "this much space comes back".
public struct VideoScanner: Scanner {
    public let category: Category = .videos
    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let settings = context.settings
        let folders = settings.resolvedMediaFolders(home: context.home)
        let paths = MediaLocator.find(.video, in: folders, minSize: settings.minVideoBytes, shell: context.shell)
            .filter { !MediaLocator.isInsideGitRepo($0, home: context.home) }
            .filter { !ProjectScanner.isKept($0, Set(settings.keptProjects.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) })) }

        var items: [CleanupItem] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let path = paths[i]
            let url = URL(fileURLWithPath: path)
            guard let info = VideoEncoder.synchronousProbe(url), info.duration > 0 else { return }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let estimate = VideoEncoder.estimate(info, quality: settings.videoQuality)
            // Not worth it below a 25% saving: the file is already lean.
            guard estimate < Int64(Double(size) * 0.75) else { return }
            let minutes = Int(info.duration / 60), seconds = Int(info.duration) % 60
            let detail = "\(info.resolutionLabel) \(Int(info.fps.rounded()))fps · \(minutes):\(String(format: "%02d", seconds)) · "
                + "\(ByteFormat.string(size)) → about \(ByteFormat.string(estimate)) MP4"
            let item = CleanupItem(
                id: "video:\(path)", category: .videos, group: context.tilde((path as NSString).deletingLastPathComponent),
                title: (path as NSString).lastPathComponent, detail: detail, path: path, size: size - estimate,
                risk: .careful, selectedByDefault: false,
                action: .convert(MediaConversion(kind: .video, source: path, originalSize: size, estimatedSize: estimate))
            )
            lock.lock(); items.append(item); lock.unlock()
        }
        var notes: [ScanNote] = []
        if !items.isEmpty {
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            notes.append(ScanNote(category: .videos, message: "Converting all \(items.count) frees about \(ByteFormat.string(total)). Test the quality on one first."))
        }
        return (items, notes)
    }
}

/// Large PNG, TIFF and JPEG photos that shrink as HEIC.
public struct PhotoScanner: Scanner {
    public let category: Category = .photos
    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let settings = context.settings
        let kept = Set(settings.keptProjects.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) })
        let paths = MediaLocator.find(.image, in: settings.resolvedMediaFolders(home: context.home),
                                      minSize: settings.minPhotoBytes, shell: context.shell)
            .filter { PhotoEncoder.convertible.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { !MediaLocator.isInsideGitRepo($0, home: context.home) && !ProjectScanner.isKept($0, kept) }

        var items: [CleanupItem] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let info = PhotoEncoder.probe(url) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let estimate = Int64(Double(size) * PhotoEncoder.estimatedRatio(format: info.format))
            guard size - estimate > 500_000 else { continue }
            items.append(CleanupItem(
                id: "photo:\(path)", category: .photos, group: context.tilde((path as NSString).deletingLastPathComponent),
                title: (path as NSString).lastPathComponent,
                detail: "\(info.format.uppercased()) \(info.width)×\(info.height)\(PhotoEncoder.hasAlpha(url) ? ", transparent" : "") · "
                    + "\(ByteFormat.string(size)) → about \(ByteFormat.string(estimate)) HEIC",
                path: path, size: size - estimate, risk: .careful, selectedByDefault: false,
                action: .convert(MediaConversion(kind: .photo, source: path, originalSize: size, estimatedSize: estimate))
            ))
        }
        var notes: [ScanNote] = []
        if !items.isEmpty {
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            notes.append(ScanNote(category: .photos, message: "Converting all \(items.count) frees about \(ByteFormat.string(total)). Test the quality on one first."))
        }
        return (items, notes)
    }
}

/// Photos that exist more than once: byte-for-byte copies, and near copies
/// such as a resized export or a burst shot, found with Apple Vision.
public struct DuplicateScanner: Scanner {
    public let category: Category = .duplicates
    public init() {}

    struct Photo {
        var path: String
        var size: Int64
        var pixels: Int
        var date: Date
        var created: Date
    }

    /// Vision feature-print distance below which two photos count as the same
    /// picture. Low on purpose: a wrongly grouped photo would be trashed.
    static let similarityThreshold: Float = 0.25

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let kept = Set(context.settings.keptProjects.map { SafetyGuard.normalize(expandTilde($0, home: context.home)) })
        let paths = MediaLocator.find(.image, in: context.settings.resolvedMediaFolders(home: context.home), minSize: 50_000, shell: context.shell)
            .filter { !MediaLocator.isInsideGitRepo($0, home: context.home) && !ProjectScanner.isKept($0, kept) }
            .filter { !["svg", "gif", "ico", "icns", "pdf"].contains(($0 as NSString).pathExtension.lowercased()) }
            .prefix(20_000)

        let photos: [Photo] = paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) else { return nil }
            let info = PhotoEncoder.probe(url)
            return Photo(path: path, size: Int64(v.fileSize ?? 0), pixels: (info?.width ?? 0) * (info?.height ?? 0),
                         date: Self.captureDate(url) ?? v.contentModificationDate ?? .distantPast,
                         created: v.creationDate ?? .distantPast)
        }

        // 1. Exact copies: same size, then same SHA-256.
        var groups: [[Photo]] = []
        var inExactGroup = Set<String>()
        for (_, sameSize) in Dictionary(grouping: photos, by: \.size) where sameSize.count > 1 {
            let byHash = Dictionary(grouping: sameSize) { Self.sha256($0.path) ?? UUID().uuidString }
            for (_, copies) in byHash where copies.count > 1 {
                groups.append(copies)
                copies.forEach { inExactGroup.insert($0.path) }
            }
        }
        let exactGroupCount = groups.count

        // 2. Near copies: only compare photos taken within two minutes of each
        //    other. Resized exports keep the capture date; bursts are seconds
        //    apart. This keeps the comparisons linear instead of quadratic.
        let candidates = photos.filter { !inExactGroup.contains($0.path) && $0.date != .distantPast }.sorted { $0.date < $1.date }
        var prints: [String: VNFeaturePrintObservation] = [:]
        func print(_ p: Photo) -> VNFeaturePrintObservation? {
            if let cached = prints[p.path] { return cached }
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(url: URL(fileURLWithPath: p.path))
            guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return nil }
            prints[p.path] = result
            return result
        }
        var parent: [String: String] = [:]
        func root(_ x: String) -> String { var r = x; while let p = parent[r], p != r { r = p }; return r }
        for i in candidates.indices {
            var j = i + 1
            while j < candidates.count, candidates[j].date.timeIntervalSince(candidates[i].date) <= 120 {
                if let a = print(candidates[i]), let b = print(candidates[j]) {
                    var distance: Float = 1
                    if (try? a.computeDistance(&distance, to: b)) != nil, distance < Self.similarityThreshold {
                        parent[root(candidates[j].path)] = root(candidates[i].path)
                        parent[candidates[i].path] = parent[candidates[i].path] ?? candidates[i].path
                    }
                }
                j += 1
            }
        }
        let nearGroups = Dictionary(grouping: candidates.filter { parent[$0.path] != nil }) { root($0.path) }.values.filter { $0.count > 1 }
        groups += nearGroups

        // Keep the best copy of each group: most pixels, then the oldest file.
        var items: [CleanupItem] = []
        for (index, group) in groups.enumerated() {
            let exact = index < exactGroupCount
            let keeper = group.max { a, b in a.pixels != b.pixels ? a.pixels < b.pixels : a.created > b.created }!
            for photo in group where photo.path != keeper.path {
                items.append(CleanupItem(
                    id: "dup:\(photo.path)", category: .duplicates,
                    group: "Same as \(context.tilde(keeper.path))",
                    title: context.tilde(photo.path),
                    detail: (exact ? "Exact copy" : "Looks the same, \(photo.pixels < keeper.pixels ? "smaller version" : "near copy")")
                        + " · the copy with the most pixels stays · goes to the Trash",
                    path: photo.path, size: photo.size, risk: .careful, selectedByDefault: false,
                    action: .trash([photo.path])
                ))
            }
        }
        return (items, [])
    }

    static func sha256(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: raw)
    }
}
