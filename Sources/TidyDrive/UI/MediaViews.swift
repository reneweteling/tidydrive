import AVKit
import SwiftUI
import TidyDriveCore

/// Top of the Videos and Photos categories: what converting saves, which
/// quality, and whether the user has approved that quality on a test file.
struct MediaPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let category: Category
    @Binding var testing: MediaConversion.Kind?

    private var kind: MediaConversion.Kind { category == .videos ? .video : .photo }

    var body: some View {
        let items = model.items(in: category)
        let selected = items.filter { model.selection.contains($0.id) }
        let all = items.reduce(Int64(0)) { $0 + $1.size }
        let chosen = selected.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Prognosis(label: "Converting all \(items.count)", value: all)
                Prognosis(label: "Selected \(selected.count)", value: chosen)
                Spacer()
                if kind == .video {
                    Picker("Quality", selection: $settings.videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 200)
                    .help("Changing the quality asks for a new test. Rescan to update the estimates.")
                }
            }
            HStack(spacing: 10) {
                if settings.isApproved(kind) {
                    Label(kind == .video ? "You approved \(settings.videoQuality.label.lowercased()) on a test video"
                                         : "You approved the HEIC quality on a test photo",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.riskColor(.safe))
                } else {
                    Label("Test the quality on one \(kind == .video ? "video" : "photo") before converting the rest",
                          systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(settings.isApproved(kind) ? "Test again" : "Test on one") { testing = kind }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(items.isEmpty)
            }
            .font(.system(size: 12))
            Text("Each new \(kind == .video ? "MP4 (H.265, same resolution, frame rate and audio)" : "HEIC (same resolution and metadata)") is saved next to the original, under the same name. The original, for example the .\(kind == .video ? "mov" : "png"), then goes to the Trash.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.25)))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

private struct Prognosis: View {
    let label: String
    let value: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value > 0 ? "\(ByteFormat.string(value)) freed" : "–").font(.system(size: 18, weight: .bold)).monospacedDigit()
        }
    }
}

/// Converts one file into a temporary folder and shows it next to the
/// original. Nothing on disk changes until the user approves.
@MainActor
final class MediaTest: ObservableObject {
    enum State { case idle, encoding(Double), ready(original: URL, converted: URL, before: Int64, after: Int64), failed(String) }

    @Published var state: State = .idle
    let kind: MediaConversion.Kind
    let item: CleanupItem
    private var task: Task<Void, Never>?
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TidyDrive/test", isDirectory: true)

    init(kind: MediaConversion.Kind, item: CleanupItem) {
        self.kind = kind
        self.item = item
    }

    func run(quality: VideoQuality) {
        guard case .convert(let c) = item.action else { return }
        task?.cancel()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: c.source)
        let output = folder.appendingPathComponent("test-\(UUID().uuidString.prefix(6)).\(c.targetExtension)")
        state = .encoding(0)
        task = Task {
            do {
                if kind == .video {
                    try await VideoEncoder.encode(source: source, output: output, quality: quality) { fraction in
                        Task { @MainActor in if case .encoding = self.state { self.state = .encoding(fraction) } }
                    }
                } else {
                    try await Task.detached { try PhotoEncoder.encode(source: source, output: output) }.value
                }
                let after = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                state = .ready(original: source, converted: output, before: c.originalSize, after: after)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cleanUp() {
        task?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }
}

struct MediaTestSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @StateObject var test: MediaTest
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, kind: MediaConversion.Kind, item: CleanupItem) {
        self.model = model
        _test = StateObject(wrappedValue: MediaTest(kind: kind, item: item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Is this quality good enough?").font(.system(size: 18, weight: .bold))
                Spacer()
                Text(test.item.title).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            switch test.state {
            case .idle, .encoding:
                VStack(spacing: 10) {
                    Spacer()
                    if case .encoding(let f) = test.state, test.kind == .video {
                        ProgressView(value: f).frame(width: 320)
                        Text("Encoding a test copy on the media engine, \(Int(f * 100))%").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Encoding a test copy").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .failed(let message):
                Text("The test failed: \(message)").foregroundStyle(Theme.riskColor(.careful))
                Spacer()
            case .ready(let original, let converted, let before, let after):
                HStack(spacing: 12) {
                    Pane(title: "Original", subtitle: ByteFormat.string(before), url: original, kind: test.kind)
                    Pane(title: test.kind == .video ? "New MP4" : "New HEIC",
                         subtitle: "\(ByteFormat.string(after)), \(Int((1 - Double(after) / Double(max(before, 1))) * 100))% smaller",
                         url: converted, kind: test.kind)
                }
                Text(test.kind == .video
                     ? "Play both and look at fast motion and dark areas. If you approve, every selected video is converted at \(settings.videoQuality.label.lowercased()), and each original goes to the Trash."
                     : "Zoom in on fine detail and text. If you approve, every selected photo is converted, and each original goes to the Trash.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if test.kind == .video {
                    Button("Try higher quality") { step(up: true) }.disabled(settings.videoQuality.higher == nil || isBusy)
                    Button("Try smaller") { step(up: false) }.disabled(settings.videoQuality.lower == nil || isBusy)
                }
                Spacer()
                Button("Cancel") { test.cleanUp(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Looks good, use this quality") {
                    settings.approve(test.kind)
                    test.cleanUp()
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady)
            }
        }
        .padding(20)
        .frame(width: 960, height: 600)
        .onAppear { test.run(quality: settings.videoQuality) }
    }

    private var isBusy: Bool { if case .encoding = test.state { return true }; return false }
    private var isReady: Bool { if case .ready = test.state { return true }; return false }

    private func step(up: Bool) {
        guard let next = up ? settings.videoQuality.higher : settings.videoQuality.lower else { return }
        settings.videoQuality = next
        test.run(quality: next)
    }
}

private struct Pane: View {
    let title: String
    let subtitle: String
    let url: URL
    let kind: MediaConversion.Kind
    @State private var zoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if kind == .photo {
                    Toggle("100%", isOn: $zoomed).toggleStyle(.button).controlSize(.small)
                        .help("Show the centre at actual pixels")
                }
            }
            Group {
                if kind == .video {
                    PlayerView(url: url)
                } else if let image = NSImage(contentsOf: url) {
                    GeometryReader { geo in
                        if zoomed {
                            Image(nsImage: image).interpolation(.none)
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                        } else {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.player?.isMuted = true
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Shown after a cleanup that converted files: their originals are in the
/// Trash and only free space once deleted there.
struct TrashedOriginalsBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.trashedOriginalsBytes > 0 {
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(Theme.accent)
                Text("\(model.trashedOriginals.count) originals (\(ByteFormat.string(model.trashedOriginalsBytes))) are in the Trash. The space comes back when they are deleted.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Delete originals now") { Task { await model.deleteTrashedOriginals() } }
                    .help("Deletes only these originals from the Trash, nothing else that is in there")
            }
            .padding(10)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
