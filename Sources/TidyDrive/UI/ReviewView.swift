import SwiftUI
import AppKit
import TidyDriveCore

struct ReviewView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    var openDiskMap: () -> Void = {}
    @State private var category: Category?
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 262)
            Divider()
            VStack(spacing: 0) {
                if let category = current {
                    CategoryDetail(model: model, category: category)
                } else {
                    emptyState
                }
                TrashedOriginalsBanner(model: model).padding(.horizontal, 16).padding(.top, 8)
                Divider()
                footer
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { category = model.focusedCategory ?? model.visibleCategories.first }
        .onChange(of: model.focusedCategory) { _, new in if let new { category = new } }
        .sheet(isPresented: $confirming) {
            ConfirmSheet(model: model, isPresented: $confirming)
        }
    }

    private var current: Category? {
        if let category, model.enabledCategories.contains(category) { return category }
        return model.visibleCategories.first ?? model.enabledCategories.first
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let disk = model.disk {
                DiskGauge(status: disk, threshold: AppSettings.shared.threshold)
                    .padding(.bottom, 14)
            }
            ForEach(model.enabledCategories) { c in
                let selected = c == current
                let empty = model.items(in: c).isEmpty
                HStack(spacing: 8) {
                    Image(systemName: c.symbol).frame(width: 18)
                    Text(c.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if !empty {
                        Text(ByteFormat.string(model.result?.size(of: c) ?? 0))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    }
                }
                .opacity(empty && !selected ? 0.4 : 1)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accent : .clear))
                .contentShape(Rectangle())
                .onTapGesture { category = c }
            }
            Spacer()
            HStack(spacing: 14) {
                Button("Disk Map", action: openDiskMap)
                Button("Settings…", action: openSettings)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            if let result = model.result {
                Text("Scanned \(result.finishedAt.formatted(date: .omitted, time: .shortened)) in \(Int(result.duration))s")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if case .scanning(let step) = model.phase {
                ProgressView()
                Text("Scanning. \(step)").foregroundStyle(.secondary)
            } else {
                Text("Nothing to show yet").font(.title3.weight(.semibold))
                Button("Scan now") { Task { await model.scan() } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .cleaning(let done, let total, let current):
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 140)
                Text("Cleaning \(done + 1) of \(total): \(current)").lineLimit(1).truncationMode(.middle)
            case .scanning(let step):
                ProgressView().controlSize(.small)
                Text("Scanning. \(step)").foregroundStyle(.secondary)
            case .idle:
                if let report = model.lastReport {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.riskColor(.safe))
                    Text("Freed \(ByteFormat.string(report.freed)).")
                    if !report.failed.isEmpty {
                        Text("\(report.failed.count) failed:").foregroundStyle(Theme.riskColor(.careful))
                        Text(report.failed.map { "\($0.item.title) (\($0.message ?? "unknown error"))" }.joined(separator: "; "))
                            .lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).help(report.failed.map { "\($0.item.title): \($0.message ?? "")" }.joined(separator: "\n"))
                    }
                } else {
                    Text("Selected \(ByteFormat.string(model.selectedSize)) in \(model.selectedItems.count) items")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Rescan") { Task { await model.scan() } }.disabled(model.phase != .idle)
            Button {
                confirming = true
            } label: {
                Text("Clean \(ByteFormat.string(model.selectedSize))").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.phase != .idle || model.selectedSize == 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct CategoryDetail: View {
    @ObservedObject var model: AppModel
    let category: Category
    private var isScanning: Bool { if case .scanning = model.phase { return true } else { return false } }
    @State private var testing: MediaConversion.Kind?
    @State private var testItem: CleanupItem?

    var body: some View {
        let items = model.items(in: category)
        let groups = Dictionary(grouping: items, by: \.group)
            .map { (name: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.title).font(.system(size: 22, weight: .bold))
                Text(ByteFormat.string(model.result?.size(of: category) ?? 0))
                    .font(.system(size: 15)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if category.isConversion || category == .duplicates {
                    Button("Select all") { model.selection.formUnion(items.filter { !$0.isManual }.map(\.id)) }
                } else {
                    Button("Select safe") {
                        model.selection.formUnion(items.filter { $0.risk == .safe }.map(\.id))
                    }
                }
                Button("Select none") { model.selection.subtract(items.map(\.id)) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ForEach(model.notes(for: category), id: \.message) { note in
                Label(note.message, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }

            if category.isConversion {
                MediaPanel(model: model, category: category, testing: $testing)
            }
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: category.symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(model.result == nil || isScanning ? "Not scanned yet" : "Nothing to clean here")
                        .font(.title3.weight(.semibold))
                    Text(isScanning ? "The scan is still running." : "TidyDrive found nothing in this category on the last scan.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if category == .projects {
                ProjectTree(model: model, items: items)
            } else {
            List {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(model: model, item: item, onTest: category.isConversion ? { testItem = $0 } : nil)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            CheckBox(state: model.checkState(for: group.items)) { model.toggle(items: group.items) }
                            Text(group.name)
                            Spacer()
                            Text(ByteFormat.string(group.items.reduce(0) { $0 + $1.size })).monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            .listStyle(.inset)
            }
        }
        .onChange(of: testing) { _, kind in
            guard kind != nil else { return }
            // Test on the largest selected file, or the largest one when
            // nothing is selected yet: the hardest case for the encoder.
            let items = model.items(in: category)
            testItem = items.filter { model.selection.contains($0.id) }.max { $0.size < $1.size } ?? items.max { $0.size < $1.size }
            testing = nil
        }
        .sheet(item: $testItem) { item in
            MediaTestSheet(model: model, kind: category == .videos ? .video : .photo, item: item)
        }
    }
}

/// Projects as a tree: one row per project with its total, status and a pin
/// to keep it, and its dependency and build folders nested underneath.
struct ProjectTree: View {
    @ObservedObject var model: AppModel
    let items: [CleanupItem]
    @State private var sort: Sort = .size
    @State private var expanded: Set<String> = []

    enum Sort: String, CaseIterable { case size = "Size", name = "Name" }

    struct Project: Identifiable {
        var id: String { path }
        var path: String
        var name: String
        var items: [CleanupItem]
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
        var stale: Bool { items.contains { $0.group.hasPrefix("Stale") } }
        /// "last commit 4 months ago" or "uncommitted changes", shared by all its items.
        var status: String { items.first?.detail.components(separatedBy: " · ").dropFirst().joined(separator: " · ") ?? "" }
        var ecosystems: String { Array(Set(items.compactMap { $0.detail.components(separatedBy: " · ").first })).sorted().joined(separator: ", ") }
    }

    private var projects: [Project] {
        let grouped = Dictionary(grouping: items) { $0.project ?? $0.title }
        let list = grouped.map { path, items in
            Project(path: path, name: (path as NSString).lastPathComponent, items: items.sorted { $0.size > $1.size })
        }
        switch sort {
        case .size: return list.sorted { $0.size > $1.size }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(projects.count) projects").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("Sort projects by size or by name")
                Button(expanded.isEmpty ? "Expand all" : "Collapse all") {
                    expanded = expanded.isEmpty ? Set(projects.map(\.path)) : []
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            List {
                ForEach(projects) { project in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(project.path) },
                        set: { open in if open { expanded.insert(project.path) } else { expanded.remove(project.path) } }
                    )) {
                        ForEach(project.items) { item in
                            ItemRow(model: model, item: item, titleOverride: String(item.title.dropFirst(project.name.count + 1)), showPin: false)
                        }
                    } label: {
                        projectRow(project)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 10) {
            CheckBox(state: model.checkState(for: project.items)) { model.toggle(items: project.items) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name).font(.system(size: 13, weight: .semibold))
                    Text(project.stale ? "stale" : "active")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(project.stale ? Theme.riskColor(.safe) : .secondary)
                        .background((project.stale ? Theme.riskColor(.safe) : Color.secondary).opacity(0.14), in: Capsule())
                }
                Text("\(project.items.count) folder\(project.items.count == 1 ? "" : "s") · \(project.ecosystems) · \(project.status)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                model.keep(project: project.path)
            } label: {
                Label("Keep", systemImage: "pin")
            }
            .buttonStyle(.borderless)
            .help("Keep \(project.name): an active project, never offer its files for cleaning")
            Text(ByteFormat.string(project.size))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct ItemRow: View {
    @ObservedObject var model: AppModel
    let item: CleanupItem
    var titleOverride: String? = nil
    var showPin = true
    var onTest: ((CleanupItem) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if case .manual(_, let target) = item.action {
                Button("Open") { if let target { AppModel.open(target) } }
                    .controlSize(.small)
                    .disabled(target == nil)
                    .help(item.action.summary)
            } else {
                CheckBox(state: model.selection.contains(item.id) ? .on : .off) { model.toggle(item) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleOverride ?? item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if showPin, let project = item.project {
                Button { model.keep(project: project) } label: { Image(systemName: "pin") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Keep \((project as NSString).lastPathComponent): an active project, never offer its files for cleaning")
                    .accessibilityLabel("Keep project \((project as NSString).lastPathComponent)")
            }
            RiskPill(risk: item.risk)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 13)).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .contextMenu {
            if let path = item.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            if let onTest {
                Button("Test the quality on this one") { onTest(item) }
            }
            if let project = item.project {
                Divider()
                Button("Keep \((project as NSString).lastPathComponent), never clean it") { model.keep(project: project) }
            }
            Text("Action: \(item.action.summary)")
        }
        .help("\(item.risk.explanation)\nAction: \(item.action.summary)")
    }
}

struct ConfirmSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    /// What happens to an item, in words, grouped for the totals.
    enum Outcome: Int, CaseIterable {
        case deleted, trashed, command, converted
        var title: String {
            switch self {
            case .deleted: return "Deleted right away"
            case .trashed: return "Moved to the Trash, you can put it back"
            case .command: return "Removed by the tool's own command"
            case .converted: return "Converted, original to the Trash"
            }
        }
        var symbol: String {
            switch self {
            case .deleted: return "xmark.bin"
            case .trashed: return "trash"
            case .command: return "terminal"
            case .converted: return "arrow.triangle.2.circlepath"
            }
        }
    }

    static func outcome(_ item: CleanupItem) -> Outcome {
        switch item.action {
        case .delete, .manual: return .deleted
        case .trash: return .trashed
        case .commands: return .command
        case .convert: return .converted
        }
    }

    static func what(_ item: CleanupItem) -> String {
        switch item.action {
        case .delete(let paths): return paths.count > 1 ? "delete \(paths.count) folders" : "delete"
        case .trash(let paths): return paths.count > 1 ? "\(paths.count) items to the Trash" : "to the Trash"
        case .commands(let commands, _):
            let first = commands.first.map { cmd in
                ([(cmd.executable as NSString).lastPathComponent] + cmd.arguments.filter { !$0.hasPrefix("/") && $0 != "-C" }.prefix(3)).joined(separator: " ")
            } ?? "command"
            return commands.count > 1 ? "\(first) + \(commands.count - 1) more" : first
        case .convert(let c): return "convert to .\(c.targetExtension)"
        case .manual: return "manual"
        }
    }

    var body: some View {
        let items = model.selectedItems.filter { !$0.isManual }
        let careful = items.filter { $0.risk == .careful }
        let byCategory = Dictionary(grouping: items, by: \.category)
            .sorted { $0.value.reduce(0) { $0 + $1.size } > $1.value.reduce(0) { $0 + $1.size } }
        let unapproved = model.unapprovedConversions

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean \(ByteFormat.string(model.selectedSize))?").font(.system(size: 20, weight: .bold))
                Text("\(items.count) item\(items.count == 1 ? "" : "s") in \(byCategory.count) categor\(byCategory.count == 1 ? "y" : "ies"). Nothing is removed until you click Clean.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            // What happens, in totals.
            VStack(spacing: 6) {
                ForEach(Outcome.allCases, id: \.self) { outcome in
                    let list = items.filter { Self.outcome($0) == outcome }
                    if !list.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: outcome.symbol).frame(width: 18).foregroundStyle(.secondary)
                            Text(outcome.title)
                            Spacer()
                            Text("\(list.count)").monospacedDigit().foregroundStyle(.secondary)
                            Text(ByteFormat.string(list.reduce(0) { $0 + $1.size })).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Risk.allCases, id: \.self) { risk in
                        let n = items.filter { $0.risk == risk }.count
                        if n > 0 { RiskPill(risk: risk); Text("\(n)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 6) }
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))

            // Every item, per category.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(byCategory, id: \.key) { category, list in
                        Section {
                            ForEach(list.sorted { $0.size > $1.size }) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        if let path = item.path {
                                            Text((path as NSString).abbreviatingWithTildeInPath)
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(Self.what(item)).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(item.risk == .careful ? Theme.riskColor(.careful) : .secondary).lineLimit(1)
                                    Text(ByteFormat.string(item.size)).font(.system(size: 11)).monospacedDigit()
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .padding(.vertical, 5).padding(.horizontal, 4)
                                Divider().opacity(0.5)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbol).frame(width: 16)
                                Text(category.title)
                                Text("· \(list.count)").foregroundStyle(.secondary)
                                Spacer()
                                Text(ByteFormat.string(list.reduce(0) { $0 + $1.size })).monospacedDigit()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .background(.background)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)

            if !careful.isEmpty {
                Label("\(careful.count) Careful item\(careful.count == 1 ? " holds" : "s hold") data that does not come back. Check them in red above.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.riskColor(.careful))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !unapproved.isEmpty {
                Label("Test the quality first: open \(unapproved.map { $0 == .video ? "Videos to shrink" : "Photos to shrink" }.joined(separator: " and ")) and click Test on one. Or deselect those items.",
                      systemImage: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.riskColor(.careful))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Clean \(ByteFormat.string(model.selectedSize))") {
                    isPresented = false
                    Task { await model.clean() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!unapproved.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
    }
}
