import Foundation

public struct XcodeScanner: Scanner {
    public let category: Category = .xcode

    public init() {}

    struct Entry {
        var id: String
        var title: String
        var path: String
        var risk: Risk
        var selected: Bool
        var detail: String
        var perChild: Bool = false
    }

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let dev = context.path("Library/Developer")
        let entries: [Entry] = [
            Entry(id: "deriveddata", title: "DerivedData", path: "\(dev)/Xcode/DerivedData", risk: .safe, selected: true,
                  detail: "Build products and indexes. Xcode rebuilds them on the next build."),
            Entry(id: "ios-devicesupport", title: "iOS DeviceSupport", path: "\(dev)/Xcode/iOS DeviceSupport", risk: .safe, selected: true,
                  detail: "Debug symbols per iOS version, copied again when you connect a device.", perChild: true),
            Entry(id: "watchos-devicesupport", title: "watchOS DeviceSupport", path: "\(dev)/Xcode/watchOS DeviceSupport", risk: .safe, selected: true,
                  detail: "Debug symbols per watchOS version.", perChild: true),
            Entry(id: "tvos-devicesupport", title: "tvOS DeviceSupport", path: "\(dev)/Xcode/tvOS DeviceSupport", risk: .safe, selected: true,
                  detail: "Debug symbols per tvOS version.", perChild: true),
            Entry(id: "visionos-devicesupport", title: "visionOS DeviceSupport", path: "\(dev)/Xcode/visionOS DeviceSupport", risk: .safe, selected: true,
                  detail: "Debug symbols per visionOS version.", perChild: true),
            Entry(id: "previews", title: "SwiftUI Previews", path: "\(dev)/Xcode/UserData/Previews", risk: .safe, selected: true,
                  detail: "Preview simulators and their builds."),
            Entry(id: "coresim-caches", title: "CoreSimulator caches", path: "\(dev)/CoreSimulator/Caches", risk: .safe, selected: true,
                  detail: "Dyld and runtime caches for simulators."),
            Entry(id: "xcode-cache", title: "Xcode cache", path: context.path("Library/Caches/com.apple.dt.Xcode"), risk: .safe, selected: true,
                  detail: "Downloads and documentation cache."),
            Entry(id: "xcpgdevices", title: "Playground devices", path: "\(dev)/XCPGDevices", risk: .safe, selected: true,
                  detail: "Simulators made for Swift Playgrounds."),
            Entry(id: "archives", title: "Archives", path: "\(dev)/Xcode/Archives", risk: .careful, selected: false,
                  detail: "Archived builds with their dSYMs. You need them to symbolicate crash reports of shipped versions.",
                  perChild: true),
        ]

        var targets: [(Entry, String, String)] = []  // entry, path, title
        for entry in entries where FileSystem.exists(entry.path) {
            if entry.perChild {
                for child in FileSystem.subdirectories(of: entry.path) where !child.hasPrefix(".") {
                    targets.append((entry, "\(entry.path)/\(child)", "\(entry.title): \(child)"))
                }
            } else {
                targets.append((entry, entry.path, entry.title))
            }
        }

        let sizes = Sizer.sizes(targets.map(\.1))
        var items = targets.map { entry, path, title in
            CleanupItem(id: "xcode:\(path)", category: .xcode, group: entry.risk == .careful ? "Keep unless you are sure" : "Caches",
                        title: title, detail: entry.detail, path: path, size: sizes[path] ?? 0,
                        risk: entry.risk, selectedByDefault: entry.selected, action: .delete([path]))
        }

        items += extraXcodeApps(context)
        return (items, [])
    }

    /// Xcode installs other than the one `xcode-select` points at.
    private func extraXcodeApps(_ context: ScanContext) -> [CleanupItem] {
        let apps = FileSystem.children(of: "/Applications").filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
        guard apps.count > 1 else { return [] }
        let selected = context.shell.run("xcode-select", ["-p"], timeout: 10).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let others = apps.map { "/Applications/\($0)" }.filter { !selected.hasPrefix($0 + "/") }
        let sizes = Sizer.sizes(others)
        return others.map { path in
            let version = (NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "?"
            return CleanupItem(id: "xcode-app:\(path)", category: .xcode, group: "Other Xcode versions",
                               title: (path as NSString).lastPathComponent,
                               detail: "Xcode \(version). Not the active Xcode (xcode-select). Goes to the Trash.",
                               path: path, size: sizes[path] ?? 0, risk: .careful, selectedByDefault: false,
                               action: .trash([path]))
        }
    }
}

public struct SimulatorScanner: Scanner {
    public let category: Category = .simulators

    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        guard context.shell.has("xcrun"), FileSystem.exists(context.path("Library/Developer/CoreSimulator")) else {
            return ([], [])
        }
        // simctl runs `xcodebuild -runFirstLaunch` first when Xcode's setup
        // is unfinished, and that waits for a password prompt nobody sees.
        let probe = context.shell.run("xcrun", ["simctl", "list", "runtimes", "--json"], timeout: 20)
        guard probe.succeeded else {
            return ([], [ScanNote(category: .simulators, message: probe.timedOut
                ? "Xcode's simulator tool did not respond. Open Xcode once so it can finish installing its components, then rescan."
                : "Could not list simulators: \(probe.stderr.prefix(200))")])
        }
        var items: [CleanupItem] = []

        // Devices
        let devicesOut = context.shell.run("xcrun", ["simctl", "list", "devices", "--json"], timeout: 60)
        var runtimesInUse = Set<String>()
        if devicesOut.succeeded, let json = try? JSONSerialization.jsonObject(with: Data(devicesOut.stdout.utf8)) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            var unavailable: [(String, String)] = []  // udid, dataPath
            var unused: [(udid: String, name: String, data: String, last: Date?)] = []
            let iso = ISO8601DateFormatter()
            for (runtime, devices) in byRuntime {
                for device in devices {
                    guard let udid = device["udid"] as? String else { continue }
                    let dataPath = (device["dataPath"] as? String).map { ($0 as NSString).deletingLastPathComponent }
                        ?? context.path("Library/Developer/CoreSimulator/Devices/\(udid)")
                    if (device["isAvailable"] as? Bool) == false {
                        unavailable.append((udid, dataPath))
                        continue
                    }
                    runtimesInUse.insert(runtime)
                    let last = (device["lastBootedAt"] as? String).flatMap { iso.date(from: $0) }
                    if last == nil || context.now.timeIntervalSince(last!) > 90 * 86_400 {
                        let name = (device["name"] as? String) ?? udid
                        unused.append((udid, "\(name) (\(Self.runtimeName(runtime)))", dataPath, last))
                    }
                }
            }

            let sizes = Sizer.sizes(unavailable.map(\.1) + unused.map(\.data))
            if !unavailable.isEmpty {
                items.append(CleanupItem(
                    id: "sim:unavailable", category: .simulators, group: "Simulators",
                    title: "Unavailable simulators",
                    detail: "\(unavailable.count) devices for runtimes that are no longer installed",
                    path: context.path("Library/Developer/CoreSimulator/Devices"),
                    size: unavailable.reduce(0) { $0 + (sizes[$1.1] ?? 0) }, risk: .safe, selectedByDefault: true,
                    action: .commands([Command("xcrun", ["simctl", "delete", "unavailable"])], fallbackDelete: [])
                ))
            }
            for device in unused {
                let detail = device.last.map { "Last booted \(ProjectScanner.ago(Int(context.now.timeIntervalSince($0) / 86_400)))" }
                    ?? "Never booted"
                items.append(CleanupItem(
                    id: "sim:\(device.udid)", category: .simulators, group: "Simulators not used in 90 days",
                    title: device.name, detail: detail, path: device.data, size: sizes[device.data] ?? 0,
                    risk: .rebuild, selectedByDefault: false,
                    action: .commands([Command("xcrun", ["simctl", "delete", device.udid])], fallbackDelete: [])
                ))
            }
        }

        // Runtimes (Xcode 15+ keeps them as disk images managed by simctl).
        let runtimesOut = context.shell.run("xcrun", ["simctl", "runtime", "list", "--json"], timeout: 60)
        if runtimesOut.succeeded, let json = try? JSONSerialization.jsonObject(with: Data(runtimesOut.stdout.utf8)) as? [String: [String: Any]] {
            for (id, runtime) in json {
                guard (runtime["deletable"] as? Bool) != false else { continue }
                let identifier = runtime["runtimeIdentifier"] as? String ?? ""
                let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                let version = runtime["version"] as? String ?? ""
                let platform = (runtime["platformIdentifier"] as? String)?
                    .replacingOccurrences(of: "com.apple.platform.", with: "")
                    .replacingOccurrences(of: "simulator", with: "") ?? ""
                let used = runtimesInUse.contains(identifier)
                items.append(CleanupItem(
                    id: "runtime:\(id)", category: .simulators, group: used ? "Runtimes with simulators" : "Runtimes without simulators",
                    title: "\(Self.platformName(platform)) \(version) runtime",
                    detail: used ? "Your simulators use this runtime. Xcode downloads it again when needed."
                                 : "No simulator uses this runtime. Xcode downloads it again when needed.",
                    path: nil, size: size, risk: .rebuild, selectedByDefault: false,
                    action: .commands([Command("xcrun", ["simctl", "runtime", "delete", id])], fallbackDelete: [])
                ))
            }
        }
        return (items, [])
    }

    static func runtimeName(_ identifier: String) -> String {
        // com.apple.CoreSimulator.SimRuntime.iOS-17-4 -> iOS 17.4
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return identifier }
        return "\(os) " + parts.dropFirst().joined(separator: ".")
    }

    static func platformName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "iphone": return "iOS"
        case "watch": return "watchOS"
        case "appletv": return "tvOS"
        case "xr": return "visionOS"
        default: return raw
        }
    }
}

public struct AndroidScanner: Scanner {
    public let category: Category = .android

    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        var targets: [(id: String, group: String, title: String, detail: String, path: String, risk: Risk, selected: Bool)] = []

        let cache = context.path(".android/cache")
        if FileSystem.exists(cache) {
            targets.append(("android:cache", "Caches", "Android SDK cache", "Downloaded SDK metadata", cache, .safe, true))
        }
        let avdRoot = context.path(".android/avd")
        for avd in FileSystem.subdirectories(of: avdRoot) where avd.hasSuffix(".avd") {
            let name = String(avd.dropLast(4))
            targets.append(("android:avd:\(avd)", "Emulators", name, "Android Virtual Device with its disk images",
                            "\(avdRoot)/\(avd)", .rebuild, false))
        }

        let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? context.path("Library/Android/sdk")
        // Old build-tools: the newest stays.
        let buildTools = FileSystem.subdirectories(of: "\(sdk)/build-tools")
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in buildTools.dropFirst() {
            targets.append(("android:build-tools:\(version)", "SDK", "build-tools \(version)",
                            "The newest build-tools (\(buildTools[0])) stays", "\(sdk)/build-tools/\(version)", .rebuild, false))
        }
        // System images per API level.
        for api in FileSystem.subdirectories(of: "\(sdk)/system-images") {
            for tag in FileSystem.subdirectories(of: "\(sdk)/system-images/\(api)") {
                targets.append(("android:image:\(api)/\(tag)", "SDK", "System image \(api) \(tag)",
                                "Emulator image, downloaded again by the SDK manager", "\(sdk)/system-images/\(api)/\(tag)", .rebuild, false))
            }
        }

        let sizes = Sizer.sizes(targets.map(\.path))
        let items = targets.map { t in
            CleanupItem(id: t.id, category: .android, group: t.group, title: t.title, detail: t.detail, path: t.path,
                        size: sizes[t.path] ?? 0, risk: t.risk, selectedByDefault: t.selected, action: .delete([t.path]))
        }
        return (items, [])
    }
}

public struct ModelScanner: Scanner {
    public let category: Category = .models

    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        var items: [CleanupItem] = []

        // Ollama: one item per model, sized from its manifest.
        let ollama = context.path(".ollama/models")
        let manifests = "\(ollama)/manifests/registry.ollama.ai"
        for namespace in FileSystem.subdirectories(of: manifests) {
            for model in FileSystem.subdirectories(of: "\(manifests)/\(namespace)") {
                for tag in FileSystem.children(of: "\(manifests)/\(namespace)/\(model)") where !tag.hasPrefix(".") {
                    let manifest = "\(manifests)/\(namespace)/\(model)/\(tag)"
                    guard let data = FileManager.default.contents(atPath: manifest),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let layers = (json["layers"] as? [[String: Any]]) ?? []
                    let size = layers.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
                    let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
                    let mtime = FileSystem.modificationDate(manifest)
                    let detail = "Ollama model" + (mtime.map { " · pulled \(ProjectScanner.ago(Int(context.now.timeIntervalSince($0) / 86_400)))" } ?? "")
                        + " · ollama pull \(name) brings it back"
                    items.append(CleanupItem(
                        id: "ollama:\(name)", category: .models, group: "Ollama", title: name, detail: detail,
                        path: manifest, size: size, risk: .careful, selectedByDefault: false,
                        action: .commands([Command("ollama", ["rm", name])], fallbackDelete: [])
                    ))
                }
            }
        }

        // Hugging Face hub cache: one item per model repo.
        let hub = context.path(".cache/huggingface/hub")
        let repos = FileSystem.subdirectories(of: hub).filter { $0.hasPrefix("models--") || $0.hasPrefix("datasets--") }
        let sizes = Sizer.sizes(repos.map { "\(hub)/\($0)" })
        for repo in repos {
            let path = "\(hub)/\(repo)"
            let parts = repo.components(separatedBy: "--")
            let name = parts.dropFirst().joined(separator: "/")
            items.append(CleanupItem(
                id: "hf:\(repo)", category: .models, group: "Hugging Face", title: name,
                detail: "\(parts.first == "datasets" ? "Dataset" : "Model") in the Hugging Face cache, downloaded again on first use",
                path: path, size: sizes[path] ?? 0, risk: .careful, selectedByDefault: false, action: .delete([path])
            ))
        }

        // LM Studio
        let lmstudio = [context.path(".lmstudio/models"), context.path(".cache/lm-studio/models")].first(where: FileSystem.exists)
        if let lmstudio {
            for publisher in FileSystem.subdirectories(of: lmstudio) {
                for model in FileSystem.subdirectories(of: "\(lmstudio)/\(publisher)") {
                    let path = "\(lmstudio)/\(publisher)/\(model)"
                    let size = FileSystem.allocatedSize(of: URL(fileURLWithPath: path))
                    items.append(CleanupItem(
                        id: "lmstudio:\(path)", category: .models, group: "LM Studio", title: "\(publisher)/\(model)",
                        detail: "LM Studio model", path: path, size: size, risk: .careful, selectedByDefault: false,
                        action: .delete([path])
                    ))
                }
            }
        }
        return (items, [])
    }
}
