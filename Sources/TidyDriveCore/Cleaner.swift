import Foundation

public struct CleanupOutcome: Codable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: CleanupItem
    public var succeeded: Bool
    public var message: String?
    /// Where originals ended up in the Trash, so they can be deleted for good
    /// once the user is happy. Only set for conversions.
    public var trashed: [String] = []
    /// Bytes those originals take in the Trash.
    public var trashedBytes: Int64 = 0

    public init(item: CleanupItem, succeeded: Bool, message: String?, trashed: [String] = [], trashedBytes: Int64 = 0) {
        self.item = item
        self.succeeded = succeeded
        self.message = message
        self.trashed = trashed
        self.trashedBytes = trashedBytes
    }
}

public struct CleanupReport: Codable, Sendable {
    public var outcomes: [CleanupOutcome]
    /// Free space measured on the volume before and after. This is the
    /// honest number: Docker and pnpm in particular free less than they
    /// report.
    public var freeBefore: Int64
    public var freeAfter: Int64
    public var finishedAt: Date

    public init(outcomes: [CleanupOutcome], freeBefore: Int64, freeAfter: Int64, finishedAt: Date) {
        self.outcomes = outcomes
        self.freeBefore = freeBefore
        self.freeAfter = freeAfter
        self.finishedAt = finishedAt
    }

    public var freed: Int64 { max(0, freeAfter - freeBefore) }
    /// Originals of converted files waiting in the Trash.
    public var trashedOriginals: [String] { outcomes.flatMap(\.trashed) }
    public var trashedBytes: Int64 { outcomes.reduce(0) { $0 + $1.trashedBytes } }
    public var failed: [CleanupOutcome] { outcomes.filter { !$0.succeeded } }
}

public final class Cleaner: Sendable {
    let shell: Shell
    let guardrail: SafetyGuard
    let dryRun: Bool
    /// Moves a file to the Trash and returns where it ended up. Replaceable
    /// so tests do not fill the real Trash.
    let moveToTrash: @Sendable (URL) throws -> URL?

    public init(shell: Shell, guardrail: SafetyGuard, dryRun: Bool = false,
                moveToTrash: @escaping @Sendable (URL) throws -> URL? = { url in
                    var result: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                    return result as URL?
                }) {
        self.shell = shell
        self.guardrail = guardrail
        self.dryRun = dryRun
        self.moveToTrash = moveToTrash
    }

    /// Runs the actions one by one. Order matters for Docker (containers
    /// before the images they use), so this is deliberately sequential.
    public func clean(_ items: [CleanupItem], progress: (@Sendable (CleanupItem, Int, Int) -> Void)? = nil,
                      conversionProgress: (@Sendable (Double) -> Void)? = nil,
                      videoQuality: VideoQuality = .balanced) async -> CleanupReport {
        let before = FileSystem.diskStatus()?.available ?? 0
        var outcomes: [CleanupOutcome] = []
        for (index, item) in items.enumerated() {
            progress?(item, index, items.count)
            let outcome: CleanupOutcome
            if case .convert(let conversion) = item.action {
                outcome = await convert(conversion, item: item, quality: videoQuality, progress: conversionProgress)
            } else {
                outcome = await Task.detached(priority: .userInitiated) { [self] in self.perform(item) }.value
            }
            outcomes.append(outcome)
        }
        // Give APFS a moment to account freed blocks.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let after = FileSystem.diskStatus()?.available ?? 0
        return CleanupReport(outcomes: outcomes, freeBefore: before, freeAfter: after, finishedAt: Date())
    }

    func perform(_ item: CleanupItem) -> CleanupOutcome {
        switch item.action {
        case .delete(let paths):
            return removeAll(paths, item: item, trash: false)
        case .trash(let paths):
            return removeAll(paths, item: item, trash: true)
        case .commands(let commands, let fallback):
            let missing = commands.first { !shell.has($0.executable) }
            if missing != nil {
                guard !fallback.isEmpty else {
                    return CleanupOutcome(item: item, succeeded: false, message: "\(missing!.executable) is not installed")
                }
                return removeAll(fallback, item: item, trash: false)
            }
            for command in commands {
                if dryRun { continue }
                let result = shell.run(command, timeout: 900)
                if !result.succeeded {
                    let reason = result.timedOut ? "timed out" : (result.stderr.isEmpty ? result.stdout : result.stderr)
                    return CleanupOutcome(item: item, succeeded: false,
                                          message: "\(command.display) failed: \(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
                }
            }
            return CleanupOutcome(item: item, succeeded: true, message: nil)
        case .convert:
            return CleanupOutcome(item: item, succeeded: false, message: "Conversions run through convert()")
        case .manual(let instructions, _):
            return CleanupOutcome(item: item, succeeded: false, message: instructions)
        }
    }

    // MARK: - Conversions

    /// Encodes next to the original under a hidden temporary name, checks the
    /// result, copies the original's dates, gives it its final name and only
    /// then moves the original to the Trash. Any failure leaves the original
    /// untouched and removes the partial file.
    func convert(_ c: MediaConversion, item: CleanupItem, quality: VideoQuality,
                 progress: (@Sendable (Double) -> Void)?) async -> CleanupOutcome {
        let source = URL(fileURLWithPath: c.source)
        if case .refused(let reason) = guardrail.check(c.source, forTrash: true) {
            return CleanupOutcome(item: item, succeeded: false, message: "Refused \(c.source): \(reason)")
        }
        guard FileManager.default.fileExists(atPath: c.source) else {
            return CleanupOutcome(item: item, succeeded: false, message: "The file is gone")
        }
        if dryRun { return CleanupOutcome(item: item, succeeded: true, message: nil) }

        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let temp = dir.appendingPathComponent(".\(base).tidydrive-\(UUID().uuidString.prefix(8)).\(c.targetExtension)")
        do {
            switch c.kind {
            case .video:
                try await VideoEncoder.encode(source: source, output: temp, quality: quality) { progress?($0) }
                try await VideoEncoder.verify(original: source, converted: temp)
            case .photo:
                try PhotoEncoder.encode(source: source, output: temp)
                try PhotoEncoder.verify(original: source, converted: temp)
            }
            let newSize = Int64((try temp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard newSize < c.originalSize else {
                try? FileManager.default.removeItem(at: temp)
                return CleanupOutcome(item: item, succeeded: false, message: "The new file was not smaller, the original stays")
            }
            // Keep the original's dates, so sorting by date in Finder still works.
            let attrs = try FileManager.default.attributesOfItem(atPath: c.source)
            var dates: [FileAttributeKey: Any] = [:]
            if let created = attrs[.creationDate] { dates[.creationDate] = created }
            if let modified = attrs[.modificationDate] { dates[.modificationDate] = modified }
            try FileManager.default.setAttributes(dates, ofItemAtPath: temp.path)

            let final = Self.freeName(in: dir, base: base, ext: c.targetExtension)
            try FileManager.default.moveItem(at: temp, to: final)
            let inTrash = try moveToTrash(source)
            return CleanupOutcome(item: item, succeeded: true, message: nil,
                                  trashed: [inTrash?.path].compactMap { $0 }, trashedBytes: c.originalSize)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return CleanupOutcome(item: item, succeeded: false, message: error.localizedDescription)
        }
    }

    /// x.mp4, or "x (2).mp4" when that name is taken.
    static func freeName(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Deletes converted originals from the Trash for good, after the user
    /// said so. Only paths this app put there are accepted.
    public static func deleteFromTrash(_ paths: [String], home: String) -> Int64 {
        var freed: Int64 = 0
        for path in paths where path.hasPrefix(home + "/.Trash/") {
            let size = FileSystem.allocatedSize(of: URL(fileURLWithPath: path))
            if (try? FileManager.default.removeItem(atPath: path)) != nil { freed += size }
        }
        return freed
    }

    private func removeAll(_ paths: [String], item: CleanupItem, trash: Bool) -> CleanupOutcome {
        for path in paths {
            if case .refused(let reason) = guardrail.check(path, forTrash: trash) {
                return CleanupOutcome(item: item, succeeded: false, message: "Refused \(path): \(reason)")
            }
        }
        if dryRun { return CleanupOutcome(item: item, succeeded: true, message: nil) }

        for path in paths where FileSystem.exists(path) || isSymlink(path) {
            let url = URL(fileURLWithPath: path)
            do {
                if trash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try remove(url)
                }
            } catch {
                return CleanupOutcome(item: item, succeeded: false, message: "\(path): \(error.localizedDescription)")
            }
        }
        return CleanupOutcome(item: item, succeeded: true, message: nil)
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Go's module cache and some npm packages are read-only. Make the
            // tree writable and try once more.
            _ = Shell.execute(path: "/bin/chmod", arguments: ["-R", "u+w", url.path], timeout: 300)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
