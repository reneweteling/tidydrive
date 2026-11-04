import CoreServices
import Foundation

/// Every app in /Applications and ~/Applications, with the data it keeps in
/// ~/Library and when it was last opened. Removing one moves the app and
/// all of that data to the Trash, like AppCleaner.
public struct AppScanner: Scanner {
    public let category: Category = .apps
    public init() {}

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        let lib = context.path("Library")
        let groupContainers = FileSystem.subdirectories(of: "\(lib)/Group Containers")
        let bundles = ["/Applications", context.path("Applications")].flatMap { dir in
            FileSystem.children(of: dir).filter { $0.hasSuffix(".app") }.map { "\(dir)/\($0)" }
        }

        var items: [CleanupItem] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
            let app = bundles[i]
            guard let info = NSDictionary(contentsOfFile: "\(app)/Contents/Info.plist"),
                  let bid = info["CFBundleIdentifier"] as? String,
                  bid != "com.weteling.tidydrive", bid != "com.apple.Safari" else { return }
            let rawName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            // Some apps put invisible direction marks in their name.
            let name = rawName.filter { !$0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } }
            let version = info["CFBundleShortVersionString"] as? String

            var data = [
                "\(lib)/Containers/\(bid)", "\(lib)/Application Support/\(bid)", "\(lib)/Application Support/\(name)",
                "\(lib)/Caches/\(bid)", "\(lib)/HTTPStorages/\(bid)", "\(lib)/WebKit/\(bid)",
                "\(lib)/Saved Application State/\(bid).savedState", "\(lib)/Logs/\(name)", "\(lib)/Preferences/\(bid).plist"
            ].filter(FileSystem.exists)
            data += (Self.extraData[bid] ?? []).map { "\(lib)/\($0)" }.filter(FileSystem.exists)
            // Group containers named after the app ("group.net.whatsapp.WhatsApp.shared").
            data += groupContainers.filter { $0.localizedCaseInsensitiveContains(bid) }.map { "\(lib)/Group Containers/\($0)" }
            var seen = Set<String>()
            data = data.filter { seen.insert($0).inserted }

            let appSize = FileSystem.allocatedSize(of: URL(fileURLWithPath: app))
            let dataSize = data.reduce(Int64(0)) { $0 + FileSystem.allocatedSize(of: URL(fileURLWithPath: $1)) }
            // Spotlight's last-used date, or else the last time the app wrote
            // its preferences, which happens whenever it runs.
            let lastUsed = Self.lastUsed(app) ?? FileSystem.modificationDate("\(lib)/Preferences/\(bid).plist")
            let days = lastUsed.map { Int(context.now.timeIntervalSince($0) / 86_400) }

            let group: String
            switch days {
            case nil: group = "Never opened, or macOS does not know"
            case let d? where d >= 180: group = "Not opened in 6 months"
            case let d? where d >= 30: group = "Not opened this month"
            default: group = "Used recently"
            }
            var detail = "App \(ByteFormat.string(appSize)) · data \(ByteFormat.string(dataSize))"
            if let days { detail += " · last opened \(ProjectScanner.ago(days))" }
            if let version { detail += " · \(version)" }
            if bid.hasPrefix("com.apple.") { detail += " · from Apple, reinstall from the App Store" }

            let item = CleanupItem(
                id: "app:\(bid)", category: .apps, group: group, title: name, detail: detail, path: app,
                size: appSize + dataSize, risk: .careful, selectedByDefault: false,
                action: .trash([app] + data), quitApp: bid
            )
            lock.lock(); items.append(item); lock.unlock()
        }
        return (items, [ScanNote(category: .apps, message: "Removing an app moves it and its data in ~/Library to the Trash. Settings and documents inside that data go with it.")])
    }

    /// Apps that keep their data under a vendor folder.
    static let extraData: [String: [String]] = [
        "com.google.Chrome": ["Application Support/Google/Chrome", "Caches/Google/Chrome"],
        "com.google.Chrome.canary": ["Application Support/Google/Chrome Canary"],
        "com.microsoft.edgemac": ["Application Support/Microsoft Edge", "Caches/Microsoft Edge"],
        "com.brave.Browser": ["Application Support/BraveSoftware/Brave-Browser", "Caches/BraveSoftware"],
        "company.thebrowser.Browser": ["Application Support/Arc", "Caches/Arc"],
        "org.mozilla.firefox": ["Application Support/Firefox", "Caches/Firefox"],
        "com.spotify.client": ["Application Support/Spotify", "Caches/com.spotify.client"],
        "com.valvesoftware.steam": ["Application Support/Steam"],
        "com.docker.docker": ["Containers/com.docker.docker", "Group Containers/group.com.docker"],
    ]

    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Big data that lives inside apps: virtual machines, the Docker disk image,
/// chat media, phone backups, and caches of Electron apps and browsers.
public struct AppDataScanner: Scanner {
    public let category: Category = .appData
    public init() {}

    static let cacheFolderNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache",
                                                "DawnGraphiteCache", "GrShaderCache", "ShaderCache", "CacheStorage", "ScriptCache"]

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        var items: [CleanupItem] = []
        items += virtualMachines(context)
        items += docker(context)
        items += chatAndPhone(context)
        items += appCaches(context)
        items += claude(context)
        return (items.filter { $0.size > 0 }, [])
    }

    // MARK: - Virtual machines

    private func virtualMachines(_ context: ScanContext) -> [CleanupItem] {
        let places: [(String, String, String)] = [
            ("UTM", "Library/Containers/com.utmapp.UTM/Data/Documents", ".utm"),
            ("Parallels", "Parallels", ".pvm"),
            ("Parallels", "Documents/Parallels", ".pvm"),
            ("VMware Fusion", "Virtual Machines.localized", ".vmwarevm"),
            ("VirtualBox", "VirtualBox VMs", "")
        ]
        var targets: [(String, String)] = []
        for (tool, folder, suffix) in places {
            let dir = context.path(folder)
            for name in FileSystem.children(of: dir) where !name.hasPrefix(".") && (suffix.isEmpty ? FileSystem.isDirectory("\(dir)/\(name)") : name.hasSuffix(suffix)) {
                targets.append((tool, "\(dir)/\(name)"))
            }
        }
        let sizes = Sizer.sizes(targets.map(\.1))
        return targets.map { tool, path in
            let modified = FileSystem.modificationDate(path).map { " · last changed \(ProjectScanner.ago(Int(context.now.timeIntervalSince($0) / 86_400)))" } ?? ""
            return CleanupItem(
                id: "vm:\(path)", category: .appData, group: "Virtual machines",
                title: "\(((path as NSString).lastPathComponent as NSString).deletingPathExtension) (\(tool))",
                detail: "Virtual machine with its disk\(modified) · goes to the Trash", path: path,
                size: sizes[path] ?? 0, risk: .careful, selectedByDefault: false, action: .trash([path]),
                quitApp: tool == "UTM" ? "com.utmapp.UTM" : tool
            )
        }
    }

    // MARK: - Docker Desktop

    private func docker(_ context: ScanContext) -> [CleanupItem] {
        let raw = context.path("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        guard FileSystem.exists(raw) else { return [] }
        let size = FileSystem.allocatedSize(of: URL(fileURLWithPath: raw))
        return [CleanupItem(
            id: "docker-raw", category: .appData, group: "Docker Desktop",
            title: "Docker Desktop disk image",
            detail: "\(ByteFormat.string(size)) on disk. Clean images and volumes under Docker first; Docker Desktop then gives the space back. Settings, Resources, Disk usage limit sets a ceiling.",
            path: raw, size: size, risk: .careful, selectedByDefault: false,
            action: .manual(instructions: "Clean Docker items first, then let Docker Desktop shrink its disk image", open: "com.docker.docker")
        )]
    }

    // MARK: - Chats and phones

    private func chatAndPhone(_ context: ScanContext) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let whatsapp = context.path("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message")
        if FileSystem.exists(whatsapp) {
            items.append(CleanupItem(
                id: "whatsapp", category: .appData, group: "Chats", title: "WhatsApp media",
                detail: "Photos, videos and documents from your chats. Remove them in WhatsApp, Settings, Storage and data, Manage storage, so WhatsApp stays consistent.",
                path: whatsapp, size: FileSystem.allocatedSize(of: URL(fileURLWithPath: whatsapp)), risk: .careful,
                selectedByDefault: false, action: .manual(instructions: "Open WhatsApp, Settings, Storage and data, Manage storage", open: "net.whatsapp.WhatsApp")
            ))
        }
        let messages = context.path("Library/Messages/Attachments")
        if FileSystem.exists(messages) {
            items.append(CleanupItem(
                id: "messages", category: .appData, group: "Chats", title: "Messages attachments",
                detail: "Photos and files in iMessage chats. Review them in System Settings, General, Storage, Messages.",
                path: messages, size: FileSystem.allocatedSize(of: URL(fileURLWithPath: messages)), risk: .careful,
                selectedByDefault: false, action: .manual(instructions: "Open System Settings, General, Storage, Messages",
                                                          open: "x-apple.systempreferences:com.apple.settings.Storage")
            ))
        }
        // iPhone and iPad backups made by Finder.
        let backups = context.path("Library/Application Support/MobileSync/Backup")
        for id in FileSystem.subdirectories(of: backups) {
            let path = "\(backups)/\(id)"
            let info = NSDictionary(contentsOfFile: "\(path)/Info.plist")
            let device = (info?["Device Name"] as? String) ?? "Device \(id.prefix(8))"
            let date = (info?["Last Backup Date"] as? Date).map { " · backed up \(ProjectScanner.ago(Int(context.now.timeIntervalSince($0) / 86_400)))" } ?? ""
            items.append(CleanupItem(
                id: "backup:\(id)", category: .appData, group: "iPhone and iPad backups", title: device,
                detail: "Local Finder backup\(date). Keep it unless the device is backed up to iCloud or gone.",
                path: path, size: FileSystem.allocatedSize(of: URL(fileURLWithPath: path)), risk: .careful,
                selectedByDefault: false, action: .trash([path])
            ))
        }
        for folder in ["Library/iTunes/iPhone Software Updates", "Library/iTunes/iPad Software Updates"] {
            let dir = context.path(folder)
            for file in FileSystem.children(of: dir) where file.hasSuffix(".ipsw") {
                let path = "\(dir)/\(file)"
                items.append(CleanupItem(
                    id: "ipsw:\(path)", category: .appData, group: "iPhone and iPad backups", title: file,
                    detail: "Downloaded iOS firmware, fetched again when needed", path: path,
                    size: FileSystem.allocatedSize(of: URL(fileURLWithPath: path)), risk: .safe, selectedByDefault: true,
                    action: .delete([path])
                ))
            }
        }
        return items
    }

    // MARK: - App caches

    /// Electron apps and browsers keep their caches in Application Support,
    /// not in ~/Library/Caches. They rebuild on the next launch.
    private func appCaches(_ context: ScanContext) -> [CleanupItem] {
        let support = context.path("Library/Application Support")
        let skip: Set<String> = ["Cursor", "Code", "Windsurf", "VSCodium", "Claude", "MobileSync"]
        var byApp: [String: [String]] = [:]
        func visit(_ dir: String, app: String, depth: Int) {
            for child in FileSystem.subdirectories(of: dir) {
                let path = "\(dir)/\(child)"
                if Self.cacheFolderNames.contains(child) {
                    byApp[app, default: []].append(path)
                } else if depth < 3, !child.hasPrefix(".") {
                    visit(path, app: app, depth: depth + 1)
                }
            }
        }
        for app in FileSystem.subdirectories(of: support) where !skip.contains(app) && !app.hasPrefix("com.apple") {
            visit("\(support)/\(app)", app: app, depth: 1)
        }
        let all = byApp.values.flatMap { $0 }
        let sizes = Sizer.sizes(all)
        return byApp.compactMap { app, paths in
            let size = paths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            guard size > 50_000_000 else { return nil }
            return CleanupItem(
                id: "appcache:\(app)", category: .appData, group: "App caches", title: "\(app) caches",
                detail: "\(paths.count) cache folders in Application Support, rebuilt on the next launch. Quit \(app) first.",
                path: "\(support)/\(app)", size: size, risk: .safe, selectedByDefault: false, action: .delete(paths),
                quitApp: app
            )
        }
    }

    private func claude(_ context: ScanContext) -> [CleanupItem] {
        let base = context.path("Library/Application Support/Claude")
        var items: [CleanupItem] = []
        let vm = "\(base)/vm_bundles"
        if FileSystem.exists(vm) {
            items.append(CleanupItem(
                id: "claude-vm", category: .appData, group: "App caches", title: "Claude virtual machine images",
                detail: "The sandbox Claude runs code in. Claude downloads it again the next time it needs it. Quit Claude first.",
                path: vm, size: FileSystem.allocatedSize(of: URL(fileURLWithPath: vm)), risk: .rebuild,
                selectedByDefault: false, action: .delete([vm]), quitApp: "com.anthropic.claudefordesktop"
            ))
        }
        let caches = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"].map { "\(base)/\($0)" }.filter(FileSystem.exists)
        if !caches.isEmpty {
            let sizes = Sizer.sizes(caches)
            items.append(CleanupItem(
                id: "claude-cache", category: .appData, group: "App caches", title: "Claude caches",
                detail: "Rebuilt on the next launch. Quit Claude first.", path: base,
                size: sizes.values.reduce(0, +), risk: .safe, selectedByDefault: false, action: .delete(caches),
                quitApp: "com.anthropic.claudefordesktop"
            ))
        }
        return items
    }
}
