import SwiftUI
import TidyDriveCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var openReview: (Category?) -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let disk = model.disk {
                DiskGauge(status: disk, threshold: settings.threshold)
            }
            statusBanner
            categories
            actions
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppGlyph(size: 22)
            Text("TidyDrive").font(.system(size: 15, weight: .bold))
            Spacer()
            if let finished = model.result?.finishedAt, model.phase == .idle {
                Text("Scanned \(finished.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.phase {
        case .scanning(let step):
            Banner(color: Theme.accent) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning. \(step)").lineLimit(1)
                }
            }
        case .cleaning(let done, let total, let current):
            Banner(color: Theme.accent) {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("Cleaning \(done + 1) of \(total): \(current)").lineLimit(1).truncationMode(.middle)
                }
            }
        case .idle:
            if let report = model.lastReport {
                Banner(color: Theme.riskColor(.safe)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Freed \(ByteFormat.string(report.freed))").font(.system(size: 13, weight: .semibold))
                            if !report.failed.isEmpty {
                                Text("\(report.failed.count) item\(report.failed.count == 1 ? "" : "s") could not be removed. See Review.")
                                    .font(.system(size: 11))
                            }
                        }
                        Spacer()
                        Button { model.dismissReport() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                }
            } else if model.isOverThreshold, let result = model.result {
                Banner(color: Theme.riskColor(.careful)) {
                    Text("Your disk is \(model.disk?.usedPercent ?? 0)% full. \(ByteFormat.string(model.selectedSize)) is ready to remove, \(ByteFormat.string(result.totalSize)) found in total.")
                }
            } else if model.result == nil {
                Banner(color: Theme.accent) {
                    Text("Scan to see what your developer tools left behind.")
                }
            }
        }
    }

    private var categories: some View {
        VStack(spacing: 1) {
            ForEach(model.visibleCategories) { category in
                CategoryRow(model: model, category: category) { openReview(category) }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { openReview(nil) } label: {
                Text("Review").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.result == nil)

            if model.result == nil {
                Button { Task { await model.scan() } } label: {
                    Text("Scan now").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.phase != .idle)
            } else {
                Button { Task { await model.clean() } } label: {
                    Text(model.selectedSize > 0 ? "Clean \(ByteFormat.string(model.selectedSize))" : "Nothing selected")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.phase != .idle || model.selectedSize == 0)
            }
        }
        .overlay(alignment: .top) {
            let careful = model.selectedItems.filter { $0.risk == .careful }.count
            if careful > 0 {
                Text("Includes \(careful) Careful item\(careful == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.riskColor(.careful))
                    .offset(y: -15)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Rescan") { Task { await model.scan() } }.disabled(model.phase != .idle)
            Button("Settings…", action: openSettings)
            Spacer()
            Button("Quit", action: quit)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

struct CategoryRow: View {
    @ObservedObject var model: AppModel
    let category: Category
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: model.checkState(for: category)) { model.toggle(category) }
            Image(systemName: category.symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(category.title)
            let notes = model.notes(for: category)
            if model.items(in: category).isEmpty, !notes.isEmpty {
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(notes[0].message)
            }
            Spacer()
            let selected = model.selectedSize(in: category)
            let total = model.result?.size(of: category) ?? 0
            if selected > 0 && selected < total {
                Text(ByteFormat.string(selected)).foregroundStyle(.primary)
                Text("of \(ByteFormat.string(total))").foregroundStyle(.secondary)
            } else {
                Text(ByteFormat.string(total)).foregroundStyle(selected > 0 ? .primary : .secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.accent.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}

struct Banner<Content: View>: View {
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35)))
    }
}

/// The gauge arc from the app icon, drawn in SwiftUI.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(Theme.ink)
            GaugeArc(fraction: 1).stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .padding(size * 0.2)
            GaugeArc(fraction: 0.62).stroke(Theme.accent, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

struct GaugeArc: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.12)
        let radius = min(rect.width / 2, rect.height * 0.85)
        p.addArc(center: center, radius: radius, startAngle: .degrees(180),
                 endAngle: .degrees(180 + 180 * fraction), clockwise: false)
        return p
    }
}
