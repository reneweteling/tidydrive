import SwiftUI
import TidyDriveCore

enum Theme {
    /// Vermilion, the same accent as the website.
    static let accent = Color(red: 1.0, green: 0.353, blue: 0.212)
    static let ink = Color(red: 0.051, green: 0.082, blue: 0.090)

    static func riskColor(_ risk: Risk) -> Color {
        switch risk {
        case .safe: return Color(red: 0.13, green: 0.62, blue: 0.38)
        case .rebuild: return Color(red: 0.85, green: 0.58, blue: 0.10)
        case .careful: return Color(red: 0.86, green: 0.23, blue: 0.18)
        }
    }

    static func usageColor(_ fraction: Double, threshold: Double) -> Color {
        if fraction >= threshold { return riskColor(.careful) }
        if fraction >= threshold - 0.1 { return riskColor(.rebuild) }
        return accent
    }
}

struct RiskPill: View {
    let risk: Risk

    var body: some View {
        Text(risk.label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Theme.riskColor(risk))
            .background(Theme.riskColor(risk).opacity(0.14), in: Capsule())
            .help(risk.explanation)
    }
}

enum CheckState { case on, off, mixed }

struct CheckBox: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(state == .off ? Color.secondary.opacity(0.6) : Theme.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(state == .off ? Color.clear : Theme.accent))
                switch state {
                case .on: Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                case .mixed: Rectangle().fill(.white).frame(width: 7, height: 2)
                case .off: EmptyView()
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }
}

struct DiskGauge: View {
    let status: DiskStatus
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(status.usedPercent)%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.usageColor(status.usedFraction, threshold: threshold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Theme.usageColor(status.usedFraction, threshold: threshold))
                        .frame(width: max(6, geo.size.width * status.usedFraction))
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: 14)
                        .offset(x: geo.size.width * threshold - 0.75)
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(ByteFormat.string(status.available)) free of \(ByteFormat.string(status.total))")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text("alert at \(Int(threshold * 100))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .monospacedDigit()
        }
    }
}
