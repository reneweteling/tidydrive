import SwiftUI
import AppKit
import TidyDriveCore

// MARK: - Model

enum DiskMapRoot: String, CaseIterable, Identifiable {
    case home, applications, disk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home folder"
        case .applications: return "Applications"
        case .disk: return "Whole disk"
        }
    }
    var path: String {
        switch self {
        case .home: return NSHomeDirectory()
        case .applications: return "/Applications"
        case .disk: return "/"
        }
    }
}

enum DiskMapSort { case name, size }

/// Decides whether a Disk Map item may be moved to the Trash.
enum DiskMapTrashPolicy {
    static func refusal(for path: String) -> String? {
        let home = NSHomeDirectory()
        if case .refused(let why) = SafetyGuard(home: home, projectRoots: []).check(path, forTrash: true) {
            return "TidyDrive will not remove this: \(why)."
        }
        let p = (path as NSString).standardizingPath
        for prefix in ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
        where p == prefix || p.hasPrefix(prefix + "/") {
            return "This is part of macOS (\(prefix))."
        }
        if p.hasPrefix("/Applications/"), p.hasSuffix(".app"),
           let owner = try? FileManager.default.attributesOfItem(atPath: p)[.ownerAccountID] as? NSNumber,
           owner.intValue == 0 {
            return "This app is owned by the system. Remove it with its own uninstaller."
        }
        for rel in ["Library/Mobile Documents", "Library/Mail", "Library/Messages"] {
            let guarded = home + "/" + rel
            if p == guarded || p.hasPrefix(guarded + "/") { return "This holds personal data (\(rel))." }
        }
        let pictures = home + "/Pictures/"
        if p.hasPrefix(pictures), p.dropFirst(pictures.count).split(separator: "/").first?.hasSuffix(".photoslibrary") == true {
            return "This is your Photos library."
        }
        return nil
    }
}

@MainActor
final class DiskMapModel: ObservableObject {
    @Published var rootChoice: DiskMapRoot = .home
    @Published private(set) var tree: DiskNode?
    @Published private(set) var current: DiskNode?
    @Published private(set) var scanning = false
    @Published private(set) var bytesCounted: Int64 = 0
    @Published var selectionID: String?
    @Published var hoverID: String?
    @Published var sort: DiskMapSort = .size
    @Published var ascending = false
    @Published var pendingTrash: DiskNode?
    @Published var notice: String?
    @Published private(set) var revision = 0

    var selected: DiskNode? { current?.children.first { $0.id == selectionID } }

    var items: [DiskNode] {
        let list = current?.children ?? []
        switch sort {
        case .size: return list.sorted { ascending ? $0.size < $1.size : $0.size > $1.size }
        case .name:
            return list.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            }
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        bytesCounted = 0
        notice = nil
        selectionID = nil
        let path = rootChoice.path
        Task { [weak self] in
            let node = await DiskMapScanner.scan(root: path) { bytes in
                Task { @MainActor in self?.bytesCounted = bytes }
            }
            guard let self else { return }
            tree = node
            current = node
            scanning = false
            revision += 1
        }
    }

    func open(_ node: DiskNode) {
        guard node.isBrowsable else { return }
        current = node
        selectionID = nil
        hoverID = nil
    }

    func goBack() {
        guard let parent = current?.parent else { return }
        current = parent
        selectionID = nil
        hoverID = nil
    }

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func requestTrash(_ node: DiskNode) {
        if node.isSynthetic {
            notice = "Smaller items is a group of many small files. Open the folder in Finder to choose from them."
        } else if let why = DiskMapTrashPolicy.refusal(for: node.path) {
            notice = why
        } else {
            notice = nil
            pendingTrash = node
        }
    }

    func confirmTrash() {
        guard let node = pendingTrash else { return }
        pendingTrash = nil
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
            node.parent?.remove(node)
            if selectionID == node.id { selectionID = nil }
            revision += 1
            objectWillChange.send()
            notice = "Moved \(node.name) to the Trash. \(ByteFormat.string(node.size)) will be free once you empty it."
        } catch {
            notice = "Could not move \(node.name) to the Trash: \(error.localizedDescription)"
        }
    }
}

// MARK: - Treemap layout

struct TreemapTile {
    let node: DiskNode
    let rect: CGRect
}

enum Treemap {
    /// Squarified layout (Bruls, Huizing, van Wijk). Input must be sorted by size, descending.
    static func layout(_ nodes: [DiskNode], in bounds: CGRect) -> [TreemapTile] {
        let items = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = items.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = Double(bounds.width * bounds.height) / total
        var remaining = bounds
        var tiles: [TreemapTile] = []
        var row: [DiskNode] = []
        var index = 0

        func worst(_ row: [DiskNode], side: Double) -> Double {
            let areas = row.map { Double($0.size) * scale }
            let sum = areas.reduce(0, +)
            guard let mx = areas.max(), let mn = areas.min(), sum > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (sum * sum), (sum * sum) / (side * side * mn))
        }

        func flush() {
            guard !row.isEmpty else { return }
            let sum = row.reduce(0.0) { $0 + Double($1.size) * scale }
            if remaining.width >= remaining.height {
                let w = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for n in row {
                    let h = CGFloat(Double(n.size) * scale) / w
                    tiles.append(TreemapTile(node: n, rect: CGRect(x: remaining.minX, y: y, width: w, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY,
                                   width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for n in row {
                    let w = CGFloat(Double(n.size) * scale) / h
                    tiles.append(TreemapTile(node: n, rect: CGRect(x: x, y: remaining.minY, width: w, height: h)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h,
                                   width: remaining.width, height: max(0, remaining.height - h))
            }
            row = []
        }

        while index < items.count {
            let side = Double(min(remaining.width, remaining.height))
            let next = items[index]
            if row.isEmpty || worst(row + [next], side: side) <= worst(row, side: side) {
                row.append(next)
                index += 1
            } else {
                flush()
            }
        }
        flush()
        return tiles
    }
}

// MARK: - Colours

private enum DiskMapPalette {
    static let smaller = Color(red: 0.55, green: 0.58, blue: 0.60)

    /// Distinct hues, dark enough for white labels in light and dark mode.
    static let hues: [Color] = [
        Color(red: 0.91, green: 0.36, blue: 0.22),  // orange
        Color(red: 0.17, green: 0.55, blue: 0.60),  // teal
        Color(red: 0.42, green: 0.36, blue: 0.80),  // violet
        Color(red: 0.20, green: 0.58, blue: 0.36),  // green
        Color(red: 0.84, green: 0.27, blue: 0.47),  // pink
        Color(red: 0.18, green: 0.45, blue: 0.78),  // blue
        Color(red: 0.80, green: 0.56, blue: 0.14),  // amber
        Color(red: 0.58, green: 0.30, blue: 0.66),  // purple
        Color(red: 0.10, green: 0.60, blue: 0.55),  // sea green
        Color(red: 0.75, green: 0.33, blue: 0.20),  // brick
    ]

    /// The colour follows the rank by size among siblings, so the biggest
    /// items differ and a folder has the same colour in the map and the list.
    static func color(for node: DiskNode, among siblings: [DiskNode]) -> Color {
        if node.isSynthetic { return smaller }
        let rank = siblings.filter { !$0.isSynthetic }.sorted { $0.size > $1.size }.firstIndex { $0.id == node.id } ?? 0
        return hues[rank % hues.count]
    }

    static func kind(_ node: DiskNode) -> String {
        if node.isSynthetic { return "\(node.itemCount) small items" }
        if node.isPackage { return "Package" }
        return node.isDirectory ? "Folder" : "File"
    }
}

// MARK: - View

struct DiskMapView: View {
    @StateObject private var model = DiskMapModel()

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.tree == nil {
                emptyState
            } else {
                HStack(spacing: 0) {
                    TreemapCanvas(model: model)
                        .padding(12)
                    Divider()
                    sidePanel.frame(width: 340)
                }
            }
            if let notice = model.notice {
                Divider()
                HStack {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { model.notice = nil }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(item: $model.pendingTrash) { node in
            TrashConfirmSheet(node: node, onCancel: { model.pendingTrash = nil }, onConfirm: { model.confirmTrash() })
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.current?.parent == nil || model.scanning)
                .help("Back")
            Picker("Scan", selection: $model.rootChoice) {
                ForEach(DiskMapRoot.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(model.scanning)
            Button(model.scanning ? "Scanning" : (model.tree == nil ? "Scan" : "Scan again")) { model.scan() }
                .disabled(model.scanning)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("\(ByteFormat.string(model.bytesCounted)) counted")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                breadcrumb
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var breadcrumb: some View {
        let chain = model.current?.ancestry ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.element.id) { i, node in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    let last = i == chain.count - 1
                    Button(node.name == "/" ? "Macintosh HD" : node.name) { model.open(node) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: last ? .semibold : .regular))
                        .foregroundStyle(last ? Color.primary : Theme.accent)
                        .disabled(last)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Disk Map").font(.system(size: 18, weight: .semibold))
            Text(model.scanning
                 ? "Reading folder sizes, \(ByteFormat.string(model.bytesCounted)) so far."
                 : "Scan a location to see which folders and files take the most space, then move what you do not need to the Trash.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack {
                sortButton("Name", .name)
                Spacer()
                sortButton("Size", .size)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            let items = model.items
            let total = max(1, model.current?.size ?? 1)
            List(selection: $model.selectionID) {
                ForEach(items) { node in
                    row(node, total: total)
                        .tag(node.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(node) }
                        .onTapGesture { model.selectionID = node.id }
                }
            }
            .listStyle(.plain)
            Divider()
            actions
        }
    }

    private func sortButton(_ title: String, _ key: DiskMapSort) -> some View {
        Button {
            if model.sort == key { model.ascending.toggle() } else { model.sort = key; model.ascending = key == .name }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sort == key { Image(systemName: model.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func row(_ node: DiskNode, total: Int64) -> some View {
        let fraction = Double(node.size) / Double(total)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: node.isSynthetic ? "ellipsis.circle" : node.isPackage ? "shippingbox"
                      : node.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary).frame(width: 16)
                Text(node.name).lineLimit(1).truncationMode(.middle).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(ByteFormat.string(node.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(DiskMapPalette.color(for: node, among: model.current?.children ?? []))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var actions: some View {
        let node = model.selected
        return VStack(alignment: .leading, spacing: 8) {
            if let node {
                Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(DiskMapPalette.kind(node)), \(ByteFormat.string(node.size))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Select an item to see what you can do with it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { if let node { model.reveal(node) } }
                    .disabled(node == nil)
                Button("Move to Trash") { if let node { model.requestTrash(node) } }
                    .disabled(node == nil)
                    .tint(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Treemap canvas

private struct TreemapCanvas: View {
    @ObservedObject var model: DiskMapModel
    @Environment(\.colorScheme) private var scheme
    @State private var pointer: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let tiles = Treemap.layout(model.current?.children ?? [], in: bounds)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (i, tile) in tiles.enumerated() {
                        draw(tile, index: i, in: &ctx)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        pointer = p
                        model.hoverID = tiles.first { $0.rect.contains(p) }?.node.id
                    case .ended:
                        model.hoverID = nil
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard let node = tiles.first(where: { $0.rect.contains(value.location) })?.node else { return }
                        model.selectionID = node.id
                        if node.isBrowsable { model.open(node) }
                    }
                )
                if let id = model.hoverID, let tile = tiles.first(where: { $0.node.id == id }) {
                    tooltip(tile.node)
                        .offset(x: min(pointer.x + 14, max(0, geo.size.width - 220)),
                                y: min(pointer.y + 16, max(0, geo.size.height - 60)))
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func draw(_ tile: TreemapTile, index: Int, in ctx: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return }
        let hovered = model.hoverID == tile.node.id
        let selected = model.selectionID == tile.node.id
        var color = DiskMapPalette.color(for: tile.node, among: model.current?.children ?? [])
        if hovered { color = color.opacity(0.85) }
        let path = Path(roundedRect: rect, cornerRadius: 3)
        ctx.fill(path, with: .color(color))
        if hovered || selected {
            ctx.stroke(path, with: .color(selected ? Color.primary : Color.white.opacity(0.9)), lineWidth: selected ? 2.5 : 1.5)
        }
        guard rect.width > 70, rect.height > 34 else { return }
        let name = Text(tile.node.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
        let size = Text(ByteFormat.string(tile.node.size)).font(.system(size: 11)).foregroundColor(.white.opacity(0.85))
        var inner = ctx
        inner.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
        inner.draw(name, at: CGPoint(x: rect.minX + 8, y: rect.minY + 6), anchor: .topLeading)
        inner.draw(size, at: CGPoint(x: rect.minX + 8, y: rect.minY + 23), anchor: .topLeading)
    }

    private func tooltip(_ node: DiskNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text("\(DiskMapPalette.kind(node)), \(ByteFormat.string(node.size))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .frame(maxWidth: 220, alignment: .leading)
    }
}

// MARK: - Confirmation

private struct TrashConfirmSheet: View {
    let node: DiskNode
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to Trash?").font(.system(size: 16, weight: .semibold))
            Text("\(node.name), \(ByteFormat.string(node.size))")
                .font(.system(size: 13, weight: .medium))
            Text(node.path)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle)
            Text("It goes to the Trash, so you can still put it back. The space is free once you empty the Trash.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
