import SwiftUI
import AppKit

/// Settings, About: the real app icon, version and updates, then a
/// "Built by" card with René's logo, the same way Loft does it.
struct AboutView: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                updatesRow
                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://reneweteling.github.io/tidydrive/")!)
                    Link("Source", destination: URL(string: "https://github.com/reneweteling/tidydrive")!)
                    Link("Report a bug", destination: URL(string: "https://github.com/reneweteling/tidydrive/issues/new?template=bug.yml&version=\(updates.currentVersion)")!)
                }
                .font(.caption)
                builtByCard
                Text("© \(Self.year) Felobo B.V. · PolyForm Noncommercial 1.0.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .task { await updates.checkIfNeeded() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AppIconView(size: 88)
            VStack(spacing: 2) {
                Text("TidyDrive").font(.title2.weight(.semibold))
                Text("Version \(updates.currentVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Your disk is full. Take it back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var updatesRow: some View {
        HStack(spacing: 10) {
            if updates.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            } else if updates.isUpdateAvailable, let latest = updates.latestVersion {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Update available: \(latest)").font(.caption)
                Button("Download") { updates.openReleasesPage() }.controlSize(.small)
            } else if updates.lastCheckedAt != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.riskColor(.safe))
                Text("You're on the latest version").font(.caption).foregroundStyle(.secondary)
            } else if let error = updates.lastCheckError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { Task { await updates.forceCheck() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(updates.isChecking)
                .help("Check for updates")
        }
    }

    private var builtByCard: some View {
        VStack(spacing: 14) {
            Text("BUILT BY")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)

            if let logo = Self.wetelingLogo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 64)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .accessibilityLabel("Weteling logo")
            }

            VStack(spacing: 3) {
                Text("René Weteling").font(.title3.weight(.semibold))
                Text("Agentic Developer · Felobo B.V.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("One developer. A fleet of agents.")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 8) {
                PillLink(systemImage: "sparkles", label: "Start a project",
                         url: URL(string: "https://www.weteling.com/#contact")!, prominent: true)
                PillLink(systemImage: "globe", label: "weteling.com", url: URL(string: "https://www.weteling.com")!)
                PillLink(systemImage: "chevron.left.forwardslash.chevron.right", label: "reneweteling",
                         url: URL(string: "https://github.com/reneweteling")!)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    static var year: String { String(Calendar.current.component(.year, from: Date())) }

    /// The SVG is rasterised once. Handing an SVG-backed NSImage straight to
    /// SwiftUI makes CoreSVG decode on every draw, which Loft found to crash
    /// now and then. build.sh puts the file in Contents/Resources.
    static let wetelingLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "weteling-logo", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let height: CGFloat = 128
        let scale = svg.size.height > 0 ? height / svg.size.height : 1
        let size = NSSize(width: max(svg.size.width * scale, 1), height: height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }()
}

/// The app icon as macOS shows it. Outside a packaged app (swift run, the
/// asset renderer) it falls back to the SwiftUI drawing of the same icon.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        if Bundle.main.bundleIdentifier != nil, let icon = Self.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            AppGlyph(size: size * 0.8)
                .frame(width: size, height: size)
        }
    }

    static let icon: NSImage? = {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 256, height: 256)
        return image
    }()
}

private struct PillLink: View {
    let systemImage: String
    let label: String
    let url: URL
    var prominent = false
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption2)
                Text(label).font(.caption.weight(prominent ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent || hover ? Color.white : .primary)
            .background(Capsule().fill(prominent || hover ? Theme.accent : Color.secondary.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(prominent || hover ? 0 : 0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
