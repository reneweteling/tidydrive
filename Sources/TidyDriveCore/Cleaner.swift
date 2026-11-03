import Foundation

public struct CleanupOutcome: Codable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: CleanupItem
    public var succeeded: Bool
    public var message: String?

    public init(item: CleanupItem, succeeded: Bool, message: String?) {
        self.item = item
        self.succeeded = succeeded
        self.message = message
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
    public var failed: [CleanupOutcome] { outcomes.filter { !$0.succeeded } }
}

public final class Cleaner: Sendable {
    let shell: Shell
    let guardrail: SafetyGuard
    let dryRun: Bool

    public init(shell: Shell, guardrail: SafetyGuard, dryRun: Bool = false) {
        self.shell = shell
        self.guardrail = guardrail
        self.dryRun = dryRun
    }

    /// Runs the actions one by one. Order matters for Docker (containers
    /// before the images they use), so this is deliberately sequential.
    public func clean(_ items: [CleanupItem], progress: (@Sendable (CleanupItem, Int, Int) -> Void)? = nil) async -> CleanupReport {
        let before = FileSystem.diskStatus()?.available ?? 0
        var outcomes: [CleanupOutcome] = []
        for (index, item) in items.enumerated() {
            progress?(item, index, items.count)
            let outcome = await Task.detached(priority: .userInitiated) { [self] in self.perform(item) }.value
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
        }
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
