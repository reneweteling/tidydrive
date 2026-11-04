import Foundation
import ServiceManagement
import TidyDriveCore

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Published var projectRoots: [String] { didSet { defaults.set(projectRoots, forKey: "projectRoots") } }
    @Published var staleDays: Int { didSet { defaults.set(staleDays, forKey: "staleDays") } }
    @Published var thresholdPercent: Int { didSet { defaults.set(thresholdPercent, forKey: "thresholdPercent") } }
    @Published var largeFileMB: Int { didSet { defaults.set(largeFileMB, forKey: "largeFileMB") } }
    @Published var crashReports: Bool { didSet { defaults.set(crashReports, forKey: "crashReports") } }
    /// Projects the user is working on: never offered for cleaning.
    @Published var keptProjects: [String] { didSet { defaults.set(keptProjects, forKey: "keptProjects") } }
    /// Empty means the defaults: Movies, Desktop, Downloads, Documents,
    /// Pictures and the project folders.
    @Published var mediaFolders: [String] { didSet { defaults.set(mediaFolders, forKey: "mediaFolders") } }
    @Published var videoQuality: VideoQuality {
        didSet { defaults.set(videoQuality.rawValue, forKey: "videoQuality") }
    }
    /// The video quality the user looked at and approved; nil until then.
    @Published var approvedVideoQuality: VideoQuality? {
        didSet { defaults.set(approvedVideoQuality?.rawValue, forKey: "approvedVideoQuality") }
    }
    @Published var approvedPhotos: Bool { didSet { defaults.set(approvedPhotos, forKey: "approvedPhotos") } }
    @Published var disabledCategories: Set<String> {
        didSet { defaults.set(Array(disabledCategories), forKey: "disabledCategories") }
    }

    private init() {
        defaults.register(defaults: [
            "staleDays": 60, "thresholdPercent": 90, "largeFileMB": 500, "crashReports": true
        ])
        let storedRoots = defaults.stringArray(forKey: "projectRoots")
        projectRoots = storedRoots ?? ScanSettings.defaultProjectRoots(home: FileManager.default.homeDirectoryForCurrentUser.path)
            .map { $0.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
        staleDays = defaults.integer(forKey: "staleDays")
        thresholdPercent = defaults.integer(forKey: "thresholdPercent")
        largeFileMB = defaults.integer(forKey: "largeFileMB")
        crashReports = defaults.bool(forKey: "crashReports")
        disabledCategories = Set(defaults.stringArray(forKey: "disabledCategories") ?? [])
        keptProjects = defaults.stringArray(forKey: "keptProjects") ?? []
        mediaFolders = defaults.stringArray(forKey: "mediaFolders") ?? []
        videoQuality = VideoQuality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .balanced
        approvedVideoQuality = VideoQuality(rawValue: defaults.string(forKey: "approvedVideoQuality") ?? "")
        approvedPhotos = defaults.bool(forKey: "approvedPhotos")
    }

    var threshold: Double { Double(thresholdPercent) / 100 }

    var scanSettings: ScanSettings {
        ScanSettings(
            projectRoots: projectRoots,
            staleDays: staleDays,
            largeFileBytes: Int64(largeFileMB) * 1_000_000,
            categories: Set(Category.allCases.filter { !disabledCategories.contains($0.rawValue) }),
            keptProjects: keptProjects,
            mediaFolders: mediaFolders,
            videoQuality: videoQuality
        )
    }

    /// "~/projects/shop" style, so the list reads well in Settings.
    func displayPath(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func isKept(_ project: String) -> Bool {
        keptProjects.contains(displayPath(project)) || keptProjects.contains(project)
    }

    func keep(_ project: String) {
        let display = displayPath(project)
        if !keptProjects.contains(display) { keptProjects.append(display); keptProjects.sort() }
    }

    func release(_ project: String) {
        keptProjects.removeAll { $0 == project || $0 == displayPath(project) }
    }

    func isApproved(_ kind: MediaConversion.Kind) -> Bool {
        kind == .video ? approvedVideoQuality == videoQuality : approvedPhotos
    }

    func approve(_ kind: MediaConversion.Kind) {
        if kind == .video { approvedVideoQuality = videoQuality } else { approvedPhotos = true }
    }

    var effectiveMediaFolders: [String] {
        mediaFolders.isEmpty ? ["~/Movies", "~/Desktop", "~/Downloads", "~/Documents", "~/Pictures"] + projectRoots : mediaFolders
    }

    func isEnabled(_ category: Category) -> Bool { !disabledCategories.contains(category.rawValue) }

    func setEnabled(_ category: Category, _ enabled: Bool) {
        if enabled { disabledCategories.remove(category.rawValue) } else { disabledCategories.insert(category.rawValue) }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("TidyDrive: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
