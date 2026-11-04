import Foundation
import AppKit
import Combine
import TidyDriveCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle
        case scanning(String)
        case cleaning(done: Int, total: Int, current: String)
    }

    @Published private(set) var disk: DiskStatus?
    @Published private(set) var result: ScanResult?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastReport: CleanupReport?
    @Published var selection: Set<String> = []
    /// Originals of converted videos and photos, waiting in the Trash.
    @Published private(set) var trashedOriginals: [String] = []
    @Published private(set) var trashedOriginalsBytes: Int64 = 0

    /// Set when the user picked a category in the popover, so the review
    /// window opens on it.
    @Published var focusedCategory: Category?

    var onThresholdCrossed: ((DiskStatus, ScanResult?) -> Void)?

    /// Set by `--render-assets`: shows example data and never touches the disk.
    var isPreview = false

    private let settings = AppSettings.shared
    private var alarm: ThresholdAlarm
    private var resolver: ToolResolver?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {
        alarm = ThresholdAlarm(threshold: AppSettings.shared.threshold, reset: AppSettings.shared.threshold - 0.05)
        result = Self.loadCachedResult()
        if let result { selection = Set(result.items.filter(\.selectedByDefault).map(\.id)) }
        disk = FileSystem.diskStatus()

        settings.$thresholdPercent
            .dropFirst()
            .sink { [weak self] percent in
                let t = Double(percent) / 100
                self?.alarm = ThresholdAlarm(threshold: t, reset: t - 0.05)
                self?.checkDisk()
            }
            .store(in: &cancellables)
    }

    // MARK: - Disk monitoring

    func startMonitoring() {
        checkDisk()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDisk() }
        }
    }

    func checkDisk() {
        guard !isPreview, let status = FileSystem.diskStatus() else { return }
        disk = status
        if alarm.update(usedFraction: status.usedFraction) {
            // Scan first, so the notification can say how much can go.
            Task {
                if self.phase == .idle { await self.scan() }
                self.onThresholdCrossed?(status, self.result)
            }
        }
    }

    var isOverThreshold: Bool { (disk?.usedFraction ?? 0) >= settings.threshold }

    // MARK: - Scanning

    func scan() async {
        guard !isPreview, phase == .idle else { return }
        phase = .scanning("Starting")
        Telemetry.breadcrumb("scan.started")

        if resolver == nil {
            let path = await Task.detached { ToolResolver.loginShellPath() }.value
            resolver = ToolResolver(loginShellPath: path)
        }
        let context = ScanContext(home: home, settings: settings.scanSettings, shell: Shell(resolver: resolver!))
        let scanned = await ScanEngine().scan(context) { category, done, total in
            Task { @MainActor in
                if case .scanning = self.phase { self.phase = .scanning("\(category.title) done, \(done) of \(total)") }
            }
        }

        let previouslyChosen = selection
        let previousIDs = Set(result?.items.map(\.id) ?? [])
        result = scanned
        // Keep the user's choices for items that are still there, default
        // the new ones.
        selection = Set(scanned.items.compactMap { item in
            if previousIDs.contains(item.id) { return previouslyChosen.contains(item.id) ? item.id : nil }
            return item.selectedByDefault ? item.id : nil
        })
        phase = .idle
        disk = FileSystem.diskStatus()
        Self.saveCachedResult(scanned)
        Telemetry.breadcrumb("scan.finished", data: ["items": scanned.items.count, "seconds": Int(scanned.duration)])
    }

    // MARK: - Selection

    func items(in category: Category) -> [CleanupItem] { result?.items(in: category) ?? [] }

    /// Every category the user has switched on, found something or not.
    var enabledCategories: [Category] { Category.allCases.filter { settings.isEnabled($0) } }

    var visibleCategories: [Category] {
        Category.allCases.filter { settings.isEnabled($0) && (!items(in: $0).isEmpty || notes(for: $0).count > 0) }
    }

    func notes(for category: Category) -> [ScanNote] { result?.notes.filter { $0.category == category } ?? [] }

    var selectedItems: [CleanupItem] { result?.items.filter { selection.contains($0.id) } ?? [] }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func selectedSize(in category: Category) -> Int64 {
        items(in: category).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func checkState(for category: Category) -> CheckState {
        let ids = items(in: category).filter { !$0.isManual }.map(\.id)
        let chosen = ids.filter(selection.contains).count
        if chosen == 0 { return .off }
        return chosen == ids.count ? .on : .mixed
    }

    func checkState(for items: [CleanupItem]) -> CheckState {
        let items = items.filter { !$0.isManual }
        guard !items.isEmpty else { return .off }
        let chosen = items.filter { selection.contains($0.id) }.count
        if chosen == 0 { return .off }
        return chosen == items.count ? .on : .mixed
    }

    func toggle(_ item: CleanupItem) {
        guard !item.isManual else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// Toggling a whole category selects only what is not Careful. Careful
    /// items are picked one by one, on purpose.
    func toggle(_ category: Category) {
        toggle(items: items(in: category))
    }

    func toggle(items: [CleanupItem]) {
        let items = items.filter { !$0.isManual }
        let ids = items.map(\.id)
        if checkState(for: items) == .off {
            let safe = items.filter { $0.risk != .careful }.map(\.id)
            selection.formUnion(safe.isEmpty ? ids : safe)
        } else {
            selection.subtract(ids)
        }
    }

    /// Keeps a project out of every future scan and drops its items now,
    /// so the user sees the effect without waiting for a rescan.
    func keep(project: String) {
        settings.keep(project)
        guard var current = result else { return }
        let gone = Set(current.items.filter { $0.project == project }.map(\.id))
        current.items.removeAll { gone.contains($0.id) }
        result = current
        selection.subtract(gone)
        Telemetry.breadcrumb("project.kept")
    }

    func selectDefaults() {
        selection = Set(result?.items.filter(\.selectedByDefault).map(\.id) ?? [])
    }

    // MARK: - Cleaning

    func clean() async {
        let items = selectedItems
        guard !isPreview, phase == .idle, !items.isEmpty, let resolver else { return }
        phase = .cleaning(done: 0, total: items.count, current: items[0].title)
        Telemetry.breadcrumb("clean.started", data: ["items": items.count])

        // Apps (and their data) can only go while they are not running.
        let blocked = items.filter { item in item.quitApp.map(Self.isRunning) ?? false }
        let runnable = items.filter { item in !blocked.contains { $0.id == item.id } }

        let guardrail = SafetyGuard(home: home, projectRoots: settings.projectRoots.map { expandHome($0) })
        let cleaner = Cleaner(shell: Shell(resolver: resolver), guardrail: guardrail)
        let current = CurrentItem()
        var report = await cleaner.clean(runnable, progress: { item, done, total in
            current.set(item.title, done, total)
            Task { @MainActor in self.phase = .cleaning(done: done, total: total, current: item.title) }
        }, conversionProgress: { fraction in
            let (title, done, total) = current.get()
            Task { @MainActor in
                self.phase = .cleaning(done: done, total: total, current: "\(title), \(Int(fraction * 100))%")
            }
        }, videoQuality: settings.videoQuality)
        report.outcomes += blocked.map { CleanupOutcome(item: $0, succeeded: false, message: "Quit \($0.title.components(separatedBy: " caches").first ?? $0.title) first, then clean again") }
        trashedOriginals += report.trashedOriginals
        trashedOriginalsBytes += report.trashedBytes
        lastReport = report
        phase = .idle
        Telemetry.breadcrumb("clean.finished", data: ["freedMB": report.freed / 1_000_000, "failed": report.failed.count])
        for failure in report.failed {
            // Only the category and kind of action, never paths or names.
            Telemetry.captureCleanupFailure(category: failure.item.category.rawValue, action: failure.item.action.kind)
        }

        // Remove what is gone, then rescan in the background for the truth.
        let done = Set(report.outcomes.filter(\.succeeded).map(\.id))
        if var current = result {
            current.items.removeAll { done.contains($0.id) }
            result = current
        }
        selection.subtract(done)
        disk = FileSystem.diskStatus()
        await scan()
    }

    func dismissReport() { lastReport = nil }

    /// `app` is a bundle id ("com.docker.docker") or an app name ("Slack").
    static func isRunning(_ app: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app || $0.localizedName == app
        }
    }

    /// Opens an app by bundle id, or a URL such as System Settings.
    static func open(_ target: String) {
        if target.contains(":"), let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Deletes only the originals TidyDrive moved to the Trash, nothing else
    /// that is in there.
    func deleteTrashedOriginals() async {
        let paths = trashedOriginals
        _ = await Task.detached { Cleaner.deleteFromTrash(paths, home: FileManager.default.homeDirectoryForCurrentUser.path) }.value
        trashedOriginals = []
        trashedOriginalsBytes = 0
        disk = FileSystem.diskStatus()
        Telemetry.breadcrumb("originals.deleted", data: ["count": paths.count])
    }

    /// Kinds of conversion in the selection whose quality the user has not
    /// approved yet. Cleaning waits until this is empty.
    var unapprovedConversions: [MediaConversion.Kind] {
        var kinds: [MediaConversion.Kind] = []
        let selected = selectedItems
        if selected.contains(where: { $0.category == .videos }), !settings.isApproved(.video) { kinds.append(.video) }
        if selected.contains(where: { $0.category == .photos }), !settings.isApproved(.photo) { kinds.append(.photo) }
        return kinds
    }

    private func expandHome(_ path: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    // MARK: - Cache of the last scan

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TidyDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-scan.json")
    }

    private static func loadCachedResult() -> ScanResult? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }

    private static func saveCachedResult(_ result: ScanResult) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(result).write(to: cacheURL, options: .atomic)
    }

    /// Used by `--render-assets` to show the UI with example data.
    func loadPreview(result: ScanResult, disk: DiskStatus, report: CleanupReport? = nil, phase: Phase = .idle) {
        isPreview = true
        self.result = result
        self.disk = disk
        self.lastReport = report
        self.phase = phase
        selectDefaults()
    }
}

private final class CurrentItem: @unchecked Sendable {
    private var value: (String, Int, Int) = ("", 0, 0)
    private let lock = NSLock()
    func set(_ title: String, _ done: Int, _ total: Int) { lock.lock(); value = (title, done, total); lock.unlock() }
    func get() -> (String, Int, Int) { lock.lock(); defer { lock.unlock() }; return value }
}

extension CleanupAction {
    var kind: String {
        switch self {
        case .delete: return "delete"
        case .trash: return "trash"
        case .convert(let c): return "convert-\(c.kind.rawValue)"
        case .manual: return "manual"
        case .commands(let commands, _): return commands.first?.executable ?? "command"
        }
    }
}
