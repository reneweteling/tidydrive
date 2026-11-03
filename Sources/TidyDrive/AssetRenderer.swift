import AppKit
import SwiftUI
import TidyDriveCore

/// `TidyDrive --render-assets DIR` draws the real screens with example data
/// into PNGs for the website and README, plus numbered frames for the demo
/// video (see scripts/make-demo.sh). Example data only: nothing from this
/// Mac ends up in a public image.
@MainActor
enum AssetRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-assets"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // English number formatting in public images, whatever this Mac uses.
        UserDefaults.standard.setVolatileDomain(["AppleLocale": "en_US", "AppleLanguages": ["en"]], forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated { render(into: dir, demo: args.contains("--demo")) }
        return true
    }

    static func render(into dir: URL, demo: Bool) {
        let model = AppModel.shared
        model.isPreview = true
        let settings = AppSettings.shared
        let total: Int64 = 994_662_584_320

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "" : "-light"
            model.loadPreview(result: Sample.result, disk: DiskStatus(name: "Macintosh HD", total: total, available: 71_000_000_000))
            model.focusedCategory = .projects
            snapshot(popover(model, settings), size: nil, appearance: appearance, to: dir.appendingPathComponent("popover\(suffix).png"))
            snapshot(ReviewView(model: model), size: NSSize(width: 980, height: 620), appearance: appearance,
                     to: dir.appendingPathComponent("review\(suffix).png"))
            snapshot(NotificationMock(), size: nil, appearance: appearance, to: dir.appendingPathComponent("notification\(suffix).png"))
        }

        guard demo else { return }
        // Demo states for the video, dark only.
        let frames = dir.appendingPathComponent("states", isDirectory: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let full = DiskStatus(name: "Macintosh HD", total: total, available: 71_000_000_000)
        let scanSteps = ["Xcode done, 1 of 8", "Docker done, 3 of 8", "Package caches done, 5 of 8", "Projects done, 7 of 8"]
        model.loadPreview(result: ScanResult(items: [], notes: [], finishedAt: Date(), duration: 0), disk: full,
                          phase: .scanning("Starting"))
        for (i, step) in scanSteps.enumerated() {
            model.loadPreview(result: ScanResult(items: [], notes: [], finishedAt: Date(), duration: 0), disk: full, phase: .scanning(step))
            snapshot(popover(model, settings), size: nil, appearance: .darkAqua,
                     to: frames.appendingPathComponent("scan-\(i).png"))
        }
        model.loadPreview(result: Sample.result, disk: full)
        snapshot(popover(model, settings), size: nil, appearance: .darkAqua, to: frames.appendingPathComponent("results.png"))
        let selected = model.selectedItems
        for (i, item) in selected.prefix(6).enumerated() {
            model.loadPreview(result: Sample.result, disk: full, phase: .cleaning(done: i, total: selected.count, current: item.title))
            snapshot(popover(model, settings), size: nil, appearance: .darkAqua,
                     to: frames.appendingPathComponent("clean-\(i).png"))
        }
        let freed = model.selectedSize
        let after = DiskStatus(name: "Macintosh HD", total: total, available: 71_000_000_000 + freed)
        let report = CleanupReport(outcomes: [], freeBefore: 71_000_000_000, freeAfter: 71_000_000_000 + freed, finishedAt: Date())
        model.loadPreview(result: Sample.afterClean, disk: after, report: report)
        snapshot(popover(model, settings), size: nil, appearance: .darkAqua, to: frames.appendingPathComponent("done.png"))
        model.loadPreview(result: Sample.result, disk: full)
        model.focusedCategory = .docker
        snapshot(ReviewView(model: model), size: NSSize(width: 980, height: 620), appearance: .darkAqua, to: frames.appendingPathComponent("review-docker.png"))
        model.focusedCategory = .toolchains
        snapshot(ReviewView(model: model), size: NSSize(width: 980, height: 620), appearance: .darkAqua, to: frames.appendingPathComponent("review-toolchains.png"))
        model.focusedCategory = .projects
        snapshot(ReviewView(model: model), size: NSSize(width: 980, height: 620), appearance: .darkAqua, to: frames.appendingPathComponent("review-projects.png"))
    }

    private static func popover(_ model: AppModel, _ settings: AppSettings) -> some View {
        PopoverView(model: model, settings: settings, openReview: { _ in }, openSettings: {}, quit: {})
    }

    /// Renders through a real offscreen window, so AppKit-backed controls
    /// (List, Button, ProgressView) draw the way they do in the app.
    static func snapshot<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea())
        let fitting = size ?? hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out and AppKit draw.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fitting.width * scale), pixelsHigh: Int(fitting.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = fitting
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("✓ \(url.lastPathComponent) \(Int(fitting.width))x\(Int(fitting.height))")
    }
}

/// What the macOS notification looks like, for the website.
struct NotificationMock: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppGlyph(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Your disk is 90% full").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("48 GB left. TidyDrive found 64.2 GB you can remove.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(10)
    }
}

/// Example scan with made-up projects, sized like a real developer Mac.
enum Sample {
    static let GB: Int64 = 1_000_000_000
    static let MB: Int64 = 1_000_000

    static func item(_ category: Category, _ group: String, _ title: String, _ detail: String, _ size: Int64,
                     _ risk: Risk, _ selected: Bool) -> CleanupItem {
        CleanupItem(id: "\(category.rawValue):\(title)", category: category, group: group, title: title, detail: detail,
                    path: nil, size: size, risk: risk, selectedByDefault: selected, action: .delete([]))
    }

    static let items: [CleanupItem] = [
        item(.xcode, "Caches", "DerivedData", "Build products and indexes. Xcode rebuilds them on the next build.", 23_400 * MB, .safe, true),
        item(.xcode, "Caches", "iOS DeviceSupport: iPhone16,1 18.6", "Debug symbols per iOS version, copied again when you connect a device.", 4_800 * MB, .safe, true),
        item(.xcode, "Caches", "iOS DeviceSupport: iPhone15,2 17.5", "Debug symbols per iOS version, copied again when you connect a device.", 4_100 * MB, .safe, true),
        item(.xcode, "Caches", "SwiftUI Previews", "Preview simulators and their builds.", 2_900 * MB, .safe, true),
        item(.xcode, "Keep unless you are sure", "Archives: 2025-11-04", "Archived builds with their dSYMs.", 1_200 * MB, .careful, false),
        item(.simulators, "Simulators", "Unavailable simulators", "14 devices for runtimes that are no longer installed", 6_700 * MB, .safe, true),
        item(.simulators, "Runtimes without simulators", "iOS 17.5 runtime", "No simulator uses this runtime. Xcode downloads it again when needed.", 7_300 * MB, .rebuild, false),
        item(.projects, "Stale, untouched for 60+ days", "payments-api/target", "Rust · last commit 4 months ago", 9_800 * MB, .rebuild, true),
        item(.projects, "Stale, untouched for 60+ days", "acme-shop/node_modules", "JavaScript · last commit 7 months ago", 1_900 * MB, .rebuild, true),
        item(.projects, "Stale, untouched for 60+ days", "mobile-app/ios/Pods", "CocoaPods · last commit 3 months ago", 1_400 * MB, .rebuild, true),
        item(.projects, "Stale, untouched for 60+ days", "chat-server/_build", "Elixir · last commit 5 months ago", 870 * MB, .rebuild, true),
        item(.projects, "Stale, untouched for 60+ days", "ml-playground/.venv", "Python · last commit 1 years ago", 2_300 * MB, .rebuild, true),
        item(.projects, "Active", "design-system/node_modules", "JavaScript · last commit today", 1_200 * MB, .rebuild, false),
        item(.projects, "Active", "storefront/.next", "JavaScript · uncommitted changes", 2_100 * MB, .rebuild, false),
        item(.largeFiles, "Large files in your projects", "acme-shop/db/production.dump.sql.gz", "2.3 GB · changed 5 months ago · goes to the Trash", 2_300 * MB, .careful, false),
        item(.largeFiles, "Large files in your projects", "mobile-app/storage/logs/laravel.log", "1.8 GB · changed 6 days ago · goes to the Trash", 1_800 * MB, .careful, false),
        item(.caches, "JavaScript", "pnpm store", "~/Library/pnpm/store · pnpm store prune removes packages no project links to", 7_700 * MB, .safe, true),
        item(.caches, "JavaScript", "npm cache", "~/.npm/_cacache", 4_700 * MB, .safe, true),
        item(.caches, "Python", "uv cache", "~/.cache/uv", 2_400 * MB, .safe, true),
        item(.caches, "Go", "Go module cache", "~/go/pkg/mod", 1_900 * MB, .safe, true),
        item(.caches, "Testing", "Old Playwright browsers", "chromium-1140, webkit-2104 · the newest build of each browser stays", 1_400 * MB, .safe, true),
        item(.caches, "Editors", "Cursor data for deleted projects", "134 workspace folders whose project no longer exists", 850 * MB, .safe, true),
        item(.caches, "Apple", "Homebrew downloads", "~/Library/Caches/Homebrew", 640 * MB, .safe, true),
        item(.models, "Ollama", "llama3.1:70b", "Ollama model · pulled 4 months ago · ollama pull llama3.1:70b brings it back", 39_900 * MB, .careful, false),
        item(.models, "Hugging Face", "openai/whisper-large-v3", "Model in the Hugging Face cache, downloaded again on first use", 3_100 * MB, .careful, false),
        item(.toolchains, "Node", "Node 18.20.4", "asdf · none of your 31 Node projects ask for it", 210 * MB, .careful, false),
        item(.toolchains, "Python", "Python 3.11.9", "pyenv · no project asks for it", 260 * MB, .careful, false),
        item(.toolchains, "Rust", "Rust stable", "rustup · your shell uses asdf for Rust, not this one", 1_440 * MB, .careful, false),
        item(.toolchains, "Ruby", "Ruby 3.1.4", "rbenv · none of your 6 Ruby projects ask for it", 320 * MB, .careful, false),
        item(.toolchains, "Homebrew", "postgresql@14", "Also installed: postgresql@17 · nothing installed depends on postgresql@14", 180 * MB, .careful, false),
        item(.docker, "General", "Build cache", "Layers cached by docker build. The next build is slower once.", 6_200 * MB, .safe, true),
        item(.docker, "Dangling images", "<none> 4b1f0c2e9a77", "Image 4b1f0c2e9a77 · created 3 weeks ago", 1_100 * MB, .rebuild, true),
        item(.docker, "Project payments-api", "payments-api-e2e:latest", "Image e986397bade2 · created 2 days ago · removes 2 stopped containers", 7_300 * MB, .rebuild, false),
        item(.docker, "Project payments-api", "payments-api_pg_data", "Only stopped containers use this volume. It may hold a database or uploads, which do not come back.", 820 * MB, .careful, false),
        item(.docker, "Project acme-shop", "elasticsearch:8.12.0", "Image ec72548cf833 · created 2 years ago · removes 1 stopped container", 1_200 * MB, .rebuild, false),
        item(.docker, "Project acme-shop", "acme-shop_mysql", "Only stopped containers use this volume. It may hold a database or uploads, which do not come back.", 410 * MB, .careful, false),
        item(.docker, "General", "Stopped containers", "41 containers. docker compose up creates them again. Their volumes stay.", 330 * MB, .rebuild, true),
        item(.android, "SDK", "System image android-34 google_apis", "Emulator image, downloaded again by the SDK manager", 4_600 * MB, .rebuild, false),
    ]

    static var result: ScanResult {
        ScanResult(items: items.sorted { $0.size > $1.size },
                   notes: [ScanNote(category: .docker, message: "Docker Desktop keeps everything in one disk image. TidyDrive reports what was actually freed on your disk after cleaning.")],
                   finishedAt: Date().addingTimeInterval(-120), duration: 24)
    }

    static var afterClean: ScanResult {
        var r = result
        r.items.removeAll(where: \.selectedByDefault)
        return r
    }
}
