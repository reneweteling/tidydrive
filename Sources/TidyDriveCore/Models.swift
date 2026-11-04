import Foundation

/// How bad it is when an item turns out to be gone.
public enum Risk: String, Codable, CaseIterable, Sendable, Comparable {
    /// A cache the tool rebuilds by itself.
    case safe
    /// Comes back with an install, build or download. Costs time, not data.
    case rebuild
    /// May be data that does not come back. Never selected by default.
    case careful

    public var label: String {
        switch self {
        case .safe: return "Safe"
        case .rebuild: return "Rebuild"
        case .careful: return "Careful"
        }
    }

    public var explanation: String {
        switch self {
        case .safe: return "A cache the tool rebuilds by itself."
        case .rebuild: return "Comes back with an install, build or download. Costs time, not data."
        case .careful: return "May be data that does not come back."
        }
    }

    private var order: Int {
        switch self {
        case .safe: return 0
        case .rebuild: return 1
        case .careful: return 2
        }
    }

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.order < rhs.order }
}

public enum Category: String, Codable, CaseIterable, Sendable, Identifiable {
    case xcode
    case simulators
    case projects
    case largeFiles
    case caches
    case models
    case toolchains
    case docker
    case android
    case worktrees
    case videos
    case photos
    case duplicates
    case apps
    case appData

    public var id: String { rawValue }

    /// Categories that shrink files instead of deleting them.
    public var isConversion: Bool { self == .videos || self == .photos }

    public var title: String {
        switch self {
        case .xcode: return "Xcode"
        case .simulators: return "Simulators"
        case .projects: return "Projects"
        case .largeFiles: return "Large files"
        case .caches: return "Package caches"
        case .models: return "ML models"
        case .toolchains: return "Language versions"
        case .docker: return "Docker"
        case .android: return "Android"
        case .worktrees: return "Git worktrees"
        case .apps: return "Apps"
        case .appData: return "App data and VMs"
        case .videos: return "Videos to shrink"
        case .photos: return "Photos to shrink"
        case .duplicates: return "Duplicate photos"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .xcode: return "hammer"
        case .simulators: return "iphone"
        case .projects: return "folder"
        case .largeFiles: return "doc.zipper"
        case .caches: return "shippingbox"
        case .models: return "cpu"
        case .toolchains: return "chevron.left.forwardslash.chevron.right"
        case .docker: return "cube.transparent"
        case .android: return "apps.iphone"
        case .worktrees: return "arrow.triangle.branch"
        case .apps: return "app.badge"
        case .appData: return "externaldrive"
        case .videos: return "film"
        case .photos: return "photo"
        case .duplicates: return "square.on.square"
        }
    }
}

/// One process invocation. `executable` is a bare tool name resolved through
/// `ToolResolver`, or an absolute path.
public struct Command: Codable, Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    public init(_ executable: String, _ arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public var display: String {
        ([executable] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
    }
}

/// A file to re-encode in place: the new file lands next to the original,
/// which goes to the Trash once the new one checks out.
public struct MediaConversion: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, photo }
    public var kind: Kind
    public var source: String
    public var originalSize: Int64
    public var estimatedSize: Int64

    public init(kind: Kind, source: String, originalSize: Int64, estimatedSize: Int64) {
        self.kind = kind
        self.source = source
        self.originalSize = originalSize
        self.estimatedSize = estimatedSize
    }

    /// x.mov -> x.mp4, IMG.png -> IMG.heic
    public var targetExtension: String { kind == .video ? "mp4" : "heic" }
}

public enum CleanupAction: Codable, Hashable, Sendable {
    /// Remove the paths right away. For things that regenerate.
    case delete([String])
    /// Move the paths to the Trash, so they can still be restored.
    case trash([String])
    /// Run the tool's own clean command(s) in order. When a command is not
    /// installed, `fallbackDelete` paths are removed instead.
    case commands([Command], fallbackDelete: [String])
    /// Re-encode a video to MP4 or a photo to HEIC, then trash the original.
    case convert(MediaConversion)
    /// Nothing TidyDrive should delete itself: the app has its own way
    /// (WhatsApp storage manager, Docker Desktop). `open` is a bundle id or URL.
    case manual(instructions: String, open: String?)

    public var summary: String {
        switch self {
        case .delete(let paths): return paths.count == 1 ? "Delete" : "Delete \(paths.count) folders"
        case .trash: return "Move to Trash"
        case .commands(let commands, _): return commands.map(\.display).joined(separator: " && ")
        case .convert(let c): return c.kind == .video ? "Convert to H.265 MP4, original to the Trash" : "Convert to HEIC, original to the Trash"
        case .manual(let instructions, _): return instructions
        }
    }
}

public struct CleanupItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var category: Category
    /// Sub-heading inside a category, e.g. "Stale, untouched for 60+ days".
    public var group: String
    public var title: String
    public var detail: String
    /// The folder to reveal in Finder, if there is one.
    public var path: String?
    public var size: Int64
    public var risk: Risk
    public var selectedByDefault: Bool
    public var action: CleanupAction
    /// The project folder this item belongs to, for projects and large
    /// files. Lets the user keep a whole project out of future scans.
    public var project: String?
    /// App that must not be running while this is cleaned: a bundle id
    /// ("com.docker.docker") or an app name ("Slack").
    public var quitApp: String?

    public var isManual: Bool { if case .manual = action { return true } else { return false } }

    public init(id: String, category: Category, group: String, title: String, detail: String,
                path: String?, size: Int64, risk: Risk, selectedByDefault: Bool, action: CleanupAction,
                project: String? = nil, quitApp: String? = nil) {
        self.id = id
        self.category = category
        self.group = group
        self.title = title
        self.detail = detail
        self.path = path
        self.size = size
        self.risk = risk
        // Careful items are never preselected, whatever a scanner asks for.
        self.selectedByDefault = risk == .careful ? false : selectedByDefault
        self.action = action
        self.project = project
        self.quitApp = quitApp
    }
}

/// Something a scanner wants the user to know that is not an item, such as
/// "Docker is not running".
public struct ScanNote: Codable, Hashable, Sendable {
    public var category: Category
    public var message: String

    public init(category: Category, message: String) {
        self.category = category
        self.message = message
    }
}

public struct ScanResult: Codable, Sendable {
    public var items: [CleanupItem]
    public var notes: [ScanNote]
    public var finishedAt: Date
    public var duration: TimeInterval

    public init(items: [CleanupItem], notes: [ScanNote], finishedAt: Date, duration: TimeInterval) {
        self.items = items
        self.notes = notes
        self.finishedAt = finishedAt
        self.duration = duration
    }

    public func items(in category: Category) -> [CleanupItem] {
        items.filter { $0.category == category }
    }

    public func size(of category: Category) -> Int64 {
        items(in: category).reduce(0) { $0 + $1.size }
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesActualByteCount = false
        return f.string(fromByteCount: bytes)
    }
}
