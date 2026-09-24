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

final class VideoExporter {
    static let shared = VideoExporter()

    private let queue = DispatchQueue(label: "com.itzprovenom.wee.export")
    private var isCancelled = false

    func cancel() {
        queue.sync { isCancelled = true }
    }

    func export(
        source: URL,
        configuration: ExportConfiguration,
        progress: @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        isCancelled = false

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        let targetSize: CGSize
        if configuration.resolution == .custom {
            targetSize = CGSize(width: configuration.customWidth, height: configuration.customHeight)
        } else {
            let transformed = naturalSize.applying(preferredTransform)
            let absSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            targetSize = configuration.resolution.size(for: absSize)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WEE_\(UUID().uuidString).mp4")

        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ExportError.cannotCreateWriter
        }

        let codecType: AVVideoCodecType = (configuration.codec == .hevc) ? .hevc : .h264
        let pixelCount = max(1.0, targetSize.width * targetSize.height)
        let baseBitrate = 2_000_000.0 * (pixelCount / (1920.0 * 1080.0))
        let bitrate = Int(baseBitrate * configuration.quality.bitrateMultiplier)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate
        ]
        if configuration.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height)
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw ExportError.cannotCreateWriter
        }
        writer.add(writerInput)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        guard reader.canAdd(readerOutput) else {
            throw ExportError.encodingFailed("Cannot add reader output")
        }
        reader.add(readerOutput)

        let exportDuration = min(configuration.duration.seconds, CMTimeGetSeconds(duration))
        let startTime = CMTime(seconds: configuration.trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: configuration.trimStart + exportDuration, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)

        progress(ExportProgress(stage: .encoding, fraction: 0))

        let totalFramesEstimate = max(1, Int(exportDuration * Double(configuration.fps.rawValue)))

        return try await withCheckedThrowingContinuation { continuation in
            var frameCount = 0
            var finished = false

            writerInput.requestMediaDataWhenReady(on: self.queue) {
                while writerInput.isReadyForMoreMediaData && !self.isCancelled && !finished {
                    if reader.status == .reading,
                       let sample = readerOutput.copyNextSampleBuffer(),
                       CMSampleBufferIsValid(sample),
                       let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {

                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let relative = CMTimeSubtract(pts, startTime)

                        if adaptor.append(pixelBuffer, withPresentationTime: relative) {
                            frameCount += 1
                            let frac = min(1.0, Double(frameCount) / Double(totalFramesEstimate))
                            progress(ExportProgress(
                                stage: .encoding,
                                fraction: frac,
                                currentFrame: frameCount,
                                fps: Double(configuration.fps.rawValue)
                            ))
                        }
                    } else {
                        finished = true
                        writerInput.markAsFinished()

                        writer.finishWriting {
                            if self.isCancelled {
                                try? FileManager.default.removeItem(at: outputURL)
                                continuation.resume(throwing: ExportError.cancelled)
                            } else if writer.status == .completed {
                                progress(ExportProgress(stage: .finishing, fraction: 1.0))
                                continuation.resume(returning: outputURL)
                            } else {
                                let msg = writer.error?.localizedDescription ?? "Unknown writer error"
                                try? FileManager.default.removeItem(at: outputURL)
                                continuation.resume(throwing: ExportError.encodingFailed(msg))
                            }
                        }
                        return
                    }
                }

                if self.isCancelled && !finished {
                    finished = true
                    writer.cancelWriting()
                    reader.cancelReading()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: ExportError.cancelled)
                }
            }
        }
    }
}
