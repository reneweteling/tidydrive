import Foundation
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
        let ids = items(in: category).map(\.id)
        let chosen = ids.filter(selection.contains).count
        if chosen == 0 { return .off }
        return chosen == ids.count ? .on : .mixed
    }

    func checkState(for items: [CleanupItem]) -> CheckState {
        let chosen = items.filter { selection.contains($0.id) }.count
        if chosen == 0 { return .off }
        return chosen == items.count ? .on : .mixed
    }

    func toggle(_ item: CleanupItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// Toggling a whole category selects only what is not Careful. Careful
    /// items are picked one by one, on purpose.
    func toggle(_ category: Category) {
        toggle(items: items(in: category))
    }

    func toggle(items: [CleanupItem]) {
        let ids = items.map(\.id)
        if checkState(for: items) == .off {
            let safe = items.filter { $0.risk != .careful }.map(\.id)
            selection.formUnion(safe.isEmpty ? ids : safe)
        } else {
            selection.subtract(ids)
        }
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

        let guardrail = SafetyGuard(home: home, projectRoots: settings.projectRoots.map { expandHome($0) })
        let cleaner = Cleaner(shell: Shell(resolver: resolver), guardrail: guardrail)
        let report = await cleaner.clean(items) { item, done, total in
            Task { @MainActor in self.phase = .cleaning(done: done, total: total, current: item.title) }
        }
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

extension CleanupAction {
    var kind: String {
        switch self {
        case .delete: return "delete"
        case .trash: return "trash"
        case .commands(let commands, _): return commands.first?.executable ?? "command"
        }
    }
}
