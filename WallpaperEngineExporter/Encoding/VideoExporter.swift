import Foundation
import AVFoundation
import CoreMedia

enum ExportError: LocalizedError {
    case noVideoTrack
    case cannotCreateWriter
    case encodingFailed(String)
    case cancelled
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The selected file does not contain a video track."
        case .cannotCreateWriter:
            return "Could not create the video writer."
        case .encodingFailed(let msg):
            return "Encoding failed: \(msg)"
        case .cancelled:
            return "Export was cancelled."
        case .insufficientStorage:
            return "Insufficient Storage\n\nThere isn't enough free storage to export this wallpaper at the selected settings."
        }
    }
}

actor VideoExporter {
    static let shared = VideoExporter()

    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func export(
        source: URL,
        configuration: ExportConfiguration,
        progress: @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        isCancelled = false

        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        let targetSize: CGSize
        if configuration.resolution == .custom {
            targetSize = CGSize(width: configuration.customWidth, height: configuration.customHeight)
        } else {
            targetSize = configuration.resolution.size(for: naturalSize.applying(preferredTransform))
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WEE_\(UUID().uuidString).mp4")

        // Clean previous if any
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw ExportError.cannotCreateWriter
        }

        let codec: AVVideoCodecType = configuration.codec == .hevc ? .hevc : .h264

        let bitrate = Int(2_000_000 * configuration.quality.bitrateMultiplier * (targetSize.width * targetSize.height) / (1920 * 1080))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: configuration.codec == .hevc
                    ? AVVideoProfileLevelH264HighAutoLevel // placeholder; real HEVC profile differs
                    : AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height)
            ]
        )

        writer.add(writerInput)

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(readerOutput)

        let exportDuration = min(configuration.duration.seconds, CMTimeGetSeconds(duration))
        let startTime = CMTime(seconds: configuration.trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: configuration.trimStart + exportDuration, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)

        progress(ExportProgress(stage: .encoding, fraction: 0))

        var frameCount = 0
        let totalFramesEstimate = Int(exportDuration * Double(configuration.fps.rawValue))

        return try await withCheckedThrowingContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "export.queue")) {
                while writerInput.isReadyForMoreMediaData && !self.isCancelled {
                    if reader.status == .reading,
                       let sample = readerOutput.copyNextSampleBuffer(),
                       let pb = CMSampleBufferGetImageBuffer(sample) {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let relative = CMTimeSubtract(pts, startTime)
                        if adaptor.append(pb, withPresentationTime: relative) {
                            frameCount += 1
                            let frac = min(1.0, Double(frameCount) / Double(max(totalFramesEstimate, 1)))
                            progress(ExportProgress(
                                stage: .encoding,
                                fraction: frac,
                                currentFrame: frameCount,
                                fps: Double(configuration.fps.rawValue)
                            ))
                        }
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if self.isCancelled {
                                try? FileManager.default.removeItem(at: outputURL)
                                continuation.resume(throwing: ExportError.cancelled)
                            } else if writer.status == .completed {
                                progress(ExportProgress(stage: .finishing, fraction: 1.0))
                                continuation.resume(returning: outputURL)
                            } else {
                                continuation.resume(throwing: ExportError.encodingFailed(writer.error?.localizedDescription ?? "Unknown"))
                            }
                        }
                        return
                    }
                }
                if self.isCancelled {
                    writer.cancelWriting()
                    reader.cancelReading()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: ExportError.cancelled)
                }
            }
        }
    }
}
