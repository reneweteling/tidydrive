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
            TrashedOriginalsBanner(model: model)
            actions
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(size: 24)
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
                .disabled(model.phase != .idle || model.selectedSize == 0 || !model.unapprovedConversions.isEmpty)
                .help(model.unapprovedConversions.isEmpty ? "" : "Test the video or photo quality first, in Review")
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

/// The app icon, drawn in SwiftUI so it looks the same everywhere,
/// including in the rendered screenshots. Mirrors scripts/make-icon.swift.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, canvas in
            let s = canvas.width
            let rect = CGRect(x: 0, y: 0, width: s, height: s)
            let shape = Path(roundedRect: rect, cornerRadius: s * 0.225, style: .continuous)
            ctx.fill(shape, with: .linearGradient(
                Gradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.20), Color(red: 0.03, green: 0.055, blue: 0.063)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: s)))

            // SwiftUI's y grows downwards; the dial centre sits 64% down.
            let center = CGPoint(x: s / 2, y: s * 0.64)
            let r = s * 0.33
            let line = s * 0.11
            if s >= 40 {
                for i in 0...10 {
                    let a = Double.pi + Double(i) / 10 * Double.pi
                    let inner = r + s * 0.085, outer = r + s * (i % 5 == 0 ? 0.125 : 0.105)
                    var tick = Path()
                    tick.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                    tick.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
                    ctx.stroke(tick, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: max(1, s * 0.008), lineCap: .round))
                }
            }
            var track = Path()
            track.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(track, with: .color(Color(red: 0.23, green: 0.29, blue: 0.30)), style: StrokeStyle(lineWidth: line, lineCap: .round))

            let endAngle = 180 + 0.62 * 180
            var value = Path()
            value.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(endAngle), clockwise: false)
            ctx.stroke(value, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.48, blue: 0.32), Color(red: 0.91, green: 0.26, blue: 0.12)]),
                startPoint: CGPoint(x: center.x - r, y: center.y), endPoint: CGPoint(x: center.x + r, y: center.y - r)),
                style: StrokeStyle(lineWidth: line, lineCap: .round))

            let a = endAngle * .pi / 180
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + cos(a) * r * 0.72, y: center.y + sin(a) * r * 0.72))
            ctx.stroke(needle, with: .color(Color(red: 0.95, green: 0.96, blue: 0.95)), style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round))
            let hub = s * 0.075
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - hub / 2, y: center.y - hub / 2, width: hub, height: hub)),
                     with: .color(Color(red: 0.95, green: 0.96, blue: 0.95)))

            let barW = s * 0.5, barH = s * 0.055
            let bar = CGRect(x: s / 2 - barW / 2, y: s * 0.835 - barH, width: barW, height: barH)
            ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2), with: .color(Color(red: 0.23, green: 0.29, blue: 0.30)))
            ctx.fill(Path(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: barW * 0.38, height: barH), cornerRadius: barH / 2),
                     with: .color(Color(red: 0.37, green: 0.83, blue: 0.60)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
