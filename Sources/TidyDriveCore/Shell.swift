import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs command line tools. A menu bar app starts with launchd's bare PATH,
/// so tools are looked up through `ToolResolver`, which knows the places
/// developers actually install them.
public final class Shell: @unchecked Sendable {
    public let resolver: ToolResolver

    public init(resolver: ToolResolver) {
        self.resolver = resolver
    }

    public func run(_ command: Command, timeout: TimeInterval = 120) -> ProcessOutput {
        guard let path = resolver.path(for: command.executable) else {
            return ProcessOutput(status: 127, stdout: "", stderr: "\(command.executable): not found", timedOut: false)
        }
        return Shell.execute(path: path, arguments: command.arguments, workingDirectory: command.workingDirectory,
                             environment: resolver.environment, timeout: timeout)
    }

    public func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 120) -> ProcessOutput {
        run(Command(executable, arguments, workingDirectory: cwd), timeout: timeout)
    }

    public func has(_ tool: String) -> Bool { resolver.path(for: tool) != nil }

    public static func execute(path: String, arguments: [String], workingDirectory: String? = nil,
                               environment: [String: String]? = nil, timeout: TimeInterval) -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read both pipes while the process runs, or a chatty tool fills the
        // pipe buffer and blocks forever.
        let outData = LockedData()
        let errData = LockedData()
        outPipe.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessOutput(status: 126, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        return ProcessOutput(status: process.terminationStatus,
                             stdout: String(decoding: outData.value, as: UTF8.self),
                             stderr: String(decoding: errData.value, as: UTF8.self),
                             timedOut: timedOut)
    }
}

private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Finds command line tools without relying on the GUI app's PATH.
public final class ToolResolver: @unchecked Sendable {
    public let searchPath: [String]
    public let environment: [String: String]
    private var cache: [String: String?] = [:]
    private let lock = NSLock()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, loginShellPath: String? = nil) {
        let h = home.path
        // The user's own shell PATH first, so `which` matches what they see
        // in Terminal, then the usual install locations as a safety net.
        var dirs: [String] = []
        if let loginShellPath {
            dirs += loginShellPath.split(separator: ":").map(String.init)
        }
        dirs += [
            "\(h)/.asdf/shims", "\(h)/.local/share/mise/shims", "\(h)/.volta/bin",
            "\(h)/.cargo/bin", "\(h)/.local/bin", "\(h)/go/bin", "\(h)/.rbenv/shims",
            "\(h)/.pyenv/shims", "\(h)/.nodenv/shims", "\(h)/.docker/bin", "\(h)/.rd/bin",
            "\(h)/homebrew/bin", "\(h)/homebrew/sbin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        var seen = Set<String>()
        searchPath = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["HOME"] = h
        // Keep tools from asking questions or paging.
        env["CI"] = "1"
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment = env
    }

    /// The PATH an interactive login shell ends up with. Many developers set
    /// PATH in .zshrc, which only interactive shells read. Capped at a few
    /// seconds, because a slow or broken shell config must not block startup.
    public static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__TIDYDRIVE_PATH__"
        let result = Shell.execute(path: shell, arguments: ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""],
                                   timeout: 6)
        guard let start = result.stdout.range(of: marker),
              let end = result.stdout.range(of: marker, range: start.upperBound..<result.stdout.endIndex) else {
            return nil
        }
        let path = String(result.stdout[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    public func path(for tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        lock.lock()
        if let cached = cache[tool] { lock.unlock(); return cached }
        lock.unlock()

        let found = searchPath
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        lock.lock(); cache[tool] = found; lock.unlock()
        return found
    }
}
