import Foundation
import TidyDriveCore

/// `TidyDrive --report [--json] [--root PATH]...` scans and prints what it
/// would offer, without the menu bar and without removing anything.
enum CommandLineMode {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--report") else { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--root", i + 1 < args.count { roots.append(args[i + 1]); i += 1 }
            i += 1
        }
        if roots.isEmpty { roots = ScanSettings.defaultProjectRoots(home: home) }

        let resolver = ToolResolver(loginShellPath: ToolResolver.loginShellPath())
        let context = ScanContext(home: home, settings: ScanSettings(projectRoots: roots), shell: Shell(resolver: resolver))
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let started = Date()
            let result = await ScanEngine().scan(context) { category, done, total in
                let t = String(format: "%.1f", Date().timeIntervalSince(started))
                FileHandle.standardError.write("  \(done)/\(total) \(category.title) after \(t)s\n".data(using: .utf8)!)
            }
            if args.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try! encoder.encode(result), as: UTF8.self))
            } else {
                printReport(result)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return true
    }

    static func printReport(_ result: ScanResult) {
        print("TidyDrive scan, \(String(format: "%.1f", result.duration))s, \(result.items.count) items, \(ByteFormat.string(result.totalSize)) total\n")
        for category in Category.allCases {
            let items = result.items(in: category)
            let notes = result.notes.filter { $0.category == category }
            guard !items.isEmpty || !notes.isEmpty else { continue }
            let selected = items.filter(\.selectedByDefault).reduce(Int64(0)) { $0 + $1.size }
            print("■ \(category.title)  \(ByteFormat.string(result.size(of: category)))  (preselected \(ByteFormat.string(selected)))")
            for note in notes { print("  note: \(note.message)") }
            for (group, list) in Dictionary(grouping: items, by: \.group).sorted(by: { $0.key < $1.key }) {
                print("  \(group)")
                for item in list.sorted(by: { $0.size > $1.size }).prefix(12) {
                    let mark = item.selectedByDefault ? "[x]" : "[ ]"
                    print("    \(mark) \(ByteFormat.string(item.size).padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.risk.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(item.title)  · \(item.detail)")
                }
                if list.count > 12 { print("    … \(list.count - 12) more") }
            }
            print("")
        }
    }
}
