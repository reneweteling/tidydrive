import AppKit
import Foundation

/// Installs a new release over the running app: download the DMG, copy the
/// app out of it, check that it is signed by the same Apple team and passes
/// Gatekeeper, then swap the bundles once TidyDrive has quit and start it again.
enum SelfUpdater {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The bundle that would be replaced, or why updating in place is not possible.
    static func installedBundle() throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw Failure(message: "Not running from an app bundle") }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw Failure(message: "No write access to \(parent). Download the update by hand.")
        }
        return bundle
    }

    static func install(dmg url: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let current = try installedBundle()
        guard let team = teamIdentifier(of: current.path) else {
            throw Failure(message: "This copy of TidyDrive is not signed, so it cannot check an update")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TidyDriveUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        progress("Downloading")
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "Download failed with \(http.statusCode)")
        }
        let dmg = work.appendingPathComponent("TidyDrive.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        progress("Checking")
        let staged = try await Task.detached { () throws -> URL in
            let mount = work.appendingPathComponent("mnt")
            let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            guard attach.status == 0 else { throw Failure(message: "Could not open the update: \(attach.output)") }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
                throw Failure(message: "The update holds no app")
            }
            let staged = work.appendingPathComponent(app)
            let copy = run("/usr/bin/ditto", ["\(mount.path)/\(app)", staged.path])
            guard copy.status == 0 else { throw Failure(message: "Could not copy the update: \(copy.output)") }
            return staged
        }.value

        try await Task.detached {
            try verify(staged, team: team, bundleID: Bundle.main.bundleIdentifier)
        }.value

        progress("Restarting")
        // A detached shell waits for this process to quit, swaps the bundles
        // (putting the old one back if the move fails) and opens the new one.
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        backup="$1.old-$$"
        if mv "$1" "$backup"; then
          if mv "$2" "$1"; then rm -rf "$backup"; else mv "$backup" "$1"; fi
        fi
        rm -rf "$3"
        open "$1"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), current.path, staged.path, work.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// Same Apple team and bundle id as the running app, a valid signature
    /// and accepted by Gatekeeper (so notarized).
    static func verify(_ app: URL, team: String, bundleID: String?) throws {
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else { throw Failure(message: "The update's signature is not valid") }
        guard teamIdentifier(of: app.path) == team else { throw Failure(message: "The update is signed by someone else") }
        if let bundleID, Bundle(url: app)?.bundleIdentifier != bundleID {
            throw Failure(message: "The update is a different app")
        }
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else { throw Failure(message: "Gatekeeper rejects the update") }
    }

    static func teamIdentifier(of path: String) -> String? {
        let info = run("/usr/bin/codesign", ["-dv", path])
        guard info.status == 0 else { return nil }
        for line in info.output.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
