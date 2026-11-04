import AVFoundation
import Foundation
import VideoToolbox

/// How hard the H.265 encoder squeezes, as bits per pixel per frame: the knob
/// that drives HEVC file size at a fixed resolution. Same values as Loft.
public enum VideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case high, balanced, small

    public var id: String { rawValue }

    public var bitsPerPixel: Double {
        switch self {
        case .high: return 0.12
        case .balanced: return 0.08
        case .small: return 0.05
        }
    }

    public var label: String {
        switch self {
        case .high: return "High quality"
        case .balanced: return "Balanced"
        case .small: return "Smallest file"
        }
    }

    public var higher: VideoQuality? { self == .small ? .balanced : self == .balanced ? .high : nil }
    public var lower: VideoQuality? { self == .high ? .balanced : self == .balanced ? .small : nil }
}

public struct VideoInfo: Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Double
    /// Bits per second of the video track as stored.
    public var dataRate: Double
    public var codec: String
    public var hasAudio: Bool

    public var resolutionLabel: String {
        let short = min(width, height)
        switch short {
        case 2000...: return "4K"
        case 1400...: return "1440p"
        case 1000...: return "1080p"
        case 700...: return "720p"
        default: return "\(width)×\(height)"
        }
    }
}

public enum VideoEncoderError: LocalizedError {
    case unreadable, noVideoTrack, readerFailed(String), writerFailed(String), verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "macOS cannot read this file as a video."
        case .noVideoTrack: return "This file has no video track."
        case .readerFailed(let m): return "Reading failed: \(m)"
        case .writerFailed(let m): return "Writing failed: \(m)"
        case .verifyFailed(let m): return "The new file did not check out: \(m)"
        }
    }
}

/// Re-encodes a video to H.265 in an MP4 at its original resolution, frame
/// rate and orientation, with AAC audio, on the Apple Silicon media engine
/// (VideoToolbox hardware encoder). Ported from Loft.
public enum VideoEncoder {
    public static func probe(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoEncoderError.noVideoTrack }
        let (size, fps, rate, formats) = try await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        return VideoInfo(duration: duration.isFinite ? duration : 0,
                         width: abs(Int(size.width.rounded())), height: abs(Int(size.height.rounded())),
                         fps: fps > 0 ? Double(fps) : 30, dataRate: Double(rate), codec: codec, hasAudio: !audio.isEmpty)
    }

    public static func targetBitrate(_ info: VideoInfo, quality: VideoQuality) -> Int {
        var bitrate = Int(Double(info.width * info.height) * info.fps * quality.bitsPerPixel)
        // Never aim above the source. HEVC needs about half the bitrate of
        // H.264 (and far less than ProRes) for the same picture, so those
        // sources are capped at half; an HEVC source only gets a small trim.
        if info.dataRate > 0 {
            let alreadyHEVC = ["hvc1", "hev1"].contains(info.codec.lowercased())
            bitrate = min(bitrate, Int(info.dataRate * (alreadyHEVC ? 0.85 : 0.5)))
        }
        return max(bitrate, 200_000)
    }

    /// Expected size of the MP4, from the target bitrate and the duration.
    public static func estimate(_ info: VideoInfo, quality: VideoQuality) -> Int64 {
        let audio = info.hasAudio ? 128_000.0 : 0
        let bits = (Double(targetBitrate(info, quality: quality)) + audio) * info.duration
        return Int64(bits / 8 * 1.02)
    }

    public static func synchronousProbe(_ url: URL) -> VideoInfo? {
        let box = ResultBox<VideoInfo>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await probe(url)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
        return box.value
    }

    public static func encode(source: URL, output: URL, quality: VideoQuality,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw VideoEncoderError.noVideoTrack }
        let info = try await probe(source)
        let transform = try await videoTrack.load(.preferredTransform)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard info.width > 0, info.height > 0 else { throw VideoEncoderError.unreadable }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoEncoderError.readerFailed("cannot read video") }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate(info, quality: quality),
                AVVideoExpectedSourceFrameRateKey: Int(info.fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0
            ] as [String: Any],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw VideoEncoderError.writerFailed("cannot write HEVC") }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                let asbd = try? await audioTrack.load(.formatDescriptions).first
                    .map { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = Int(asbd??.mChannelsPerFrame ?? 2)
                let sampleRate = (asbd??.mSampleRate).map { $0 > 0 ? $0 : 44_100 } ?? 44_100
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: max(1, min(channels, 2)),
                    AVSampleRateKey: min(sampleRate, 48_000),
                    AVEncoderBitRateKey: 128_000
                ])
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioOutput = out
                    audioInput = input
                }
            }
        }

        guard reader.startReading() else { throw VideoEncoderError.readerFailed(reader.error?.localizedDescription ?? "start") }
        guard writer.startWriting() else { throw VideoEncoderError.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let total = info.duration
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pump(videoInput, videoOutput, "video", total, progress) }
                if let audioInput, let audioOutput {
                    group.addTask { try await pump(audioInput, audioOutput, "audio", 0, nil) }
                }
                try await group.waitForAll()
            }
            if reader.status == .failed { throw VideoEncoderError.readerFailed(reader.error?.localizedDescription ?? "read") }
            await writer.finishWriting()
            if writer.status == .failed { throw VideoEncoderError.writerFailed(writer.error?.localizedDescription ?? "write") }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
        progress(1)
    }

    /// The new file must play and last as long as the original.
    public static func verify(original: URL, converted: URL) async throws {
        let a = try await probe(original)
        let b = try await probe(converted)
        guard abs(a.duration - b.duration) <= max(1.0, a.duration * 0.01) else {
            throw VideoEncoderError.verifyFailed("duration \(Int(b.duration))s instead of \(Int(a.duration))s")
        }
        guard b.width == a.width, b.height == a.height else {
            throw VideoEncoderError.verifyFailed("resolution changed")
        }
    }

    private static func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderTrackOutput, _ label: String,
                             _ totalSeconds: Double, _ progress: (@Sendable (Double) -> Void)?) async throws {
        let queue = DispatchQueue(label: "com.weteling.tidydrive.encode.\(label)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        input.markAsFinished()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume(throwing: VideoEncoderError.writerFailed("append rejected (\(label))"))
                        return
                    }
                    if let progress, totalSeconds > 0 {
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if t.isFinite { progress(min(0.99, max(0, t / totalSeconds))) }
                    }
                }
            }
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
