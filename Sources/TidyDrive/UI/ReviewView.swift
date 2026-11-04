import SwiftUI
import AppKit
import TidyDriveCore

struct ReviewView: View {
    @ObservedObject var model: AppModel
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
        if let category, model.visibleCategories.contains(category) { return category }
        return model.visibleCategories.first
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let disk = model.disk {
                DiskGauge(status: disk, threshold: AppSettings.shared.threshold)
                    .padding(.bottom, 14)
            }
            ForEach(model.visibleCategories) { c in
                let selected = c == current
                HStack(spacing: 8) {
                    Image(systemName: c.symbol).frame(width: 18)
                    Text(c.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ByteFormat.string(model.result?.size(of: c) ?? 0))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accent : .clear))
                .contentShape(Rectangle())
                .onTapGesture { category = c }
            }
            Spacer()
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
                Button("Select safe") {
                    model.selection.formUnion(items.filter { $0.risk == .safe }.map(\.id))
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

            List {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(model: model, item: item)
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
}

struct ItemRow: View {
    @ObservedObject var model: AppModel
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: model.selection.contains(item.id) ? .on : .off) { model.toggle(item) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let project = item.project {
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

    var body: some View {
        let items = model.selectedItems
        let careful = items.filter { $0.risk == .careful }
        let trash = items.filter { if case .trash = $0.action { return true } else { return false } }

        VStack(alignment: .leading, spacing: 14) {
            Text("Clean \(ByteFormat.string(model.selectedSize))?").font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Risk.allCases, id: \.self) { risk in
                    let list = items.filter { $0.risk == risk }
                    if !list.isEmpty {
                        HStack {
                            RiskPill(risk: risk)
                            Text("\(list.count) item\(list.count == 1 ? "" : "s")")
                            Spacer()
                            Text(ByteFormat.string(list.reduce(0) { $0 + $1.size })).monospacedDigit()
                        }
                    }
                }
            }
            if !careful.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These may hold data that does not come back:").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.riskColor(.careful))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(careful) { Text("• \($0.title)").font(.system(size: 12, design: .monospaced)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            Text(trash.isEmpty
                 ? "Everything selected is deleted right away. Caches and dependencies come back when your tools need them."
                 : "\(trash.count) item\(trash.count == 1 ? " goes" : "s go") to the Trash. Everything else is deleted right away.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Clean") {
                    isPresented = false
                    Task { await model.clean() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
