import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an `ExportPlan` into a finished file.
///
/// Rule: video that is already encoded is never re-encoded. An MP4 inside a
/// package is copied byte for byte, so what the user gets is exactly what
/// Wallpaper Engine plays. Only animations and still images are encoded, since
/// they have no video stream to preserve.
enum ExportError: LocalizedError {
    case nothingToExport
    case needsRenderer(String)
    case notPlayableOnDevice(String)
    case decodeFailed(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "There is nothing in this package to export."
        case .needsRenderer(let detail), .notPlayableOnDevice(let detail):
            return detail
        case .decodeFailed(let detail):
            return "Could not read the source media: \(detail)"
        case .encodeFailed(let detail):
            return "Could not create the video: \(detail)"
        }
    }
}

struct ExportOutcome: Sendable {
    let url: URL
    let strategy: ExportStrategy
    let fidelity: ExportFidelity
    let reencoded: Bool
    let warnings: [String]

    /// Photos accepts MP4/MOV only; WebM has to stay a file.
    var canSaveToPhotos: Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }
}

struct ExportPipeline {
    var stillDuration: Double = 5.0

    // MARK: Public

    func export(plan: ExportPlan, to destination: URL, scratch: URL) throws -> ExportOutcome {
        switch plan.strategy {
        case .unsupported:
            throw ExportError.nothingToExport
        case .renderScene:
            throw ExportError.needsRenderer(plan.reason)
        case .passthrough, .preserveOriginal:
            guard let candidate = plan.candidate else { throw ExportError.nothingToExport }
            let target = destination.deletingPathExtension()
                .appendingPathExtension(candidate.fileExtension)
            try materialise(candidate, to: target)
            try verifyNonEmpty(target)
            var warnings = plan.warnings
            if plan.strategy == .preserveOriginal {
                warnings.append(
                    "\(candidate.fileExtension.uppercased()) is preserved exactly as stored. "
                    + "iOS cannot play or convert it on-device, so it is saved as a file "
                    + "rather than to Photos."
                )
            }
            return ExportOutcome(url: target, strategy: plan.strategy,
                                 fidelity: plan.fidelity, reencoded: false, warnings: warnings)

        case .encodeAnimation:
            guard let candidate = plan.candidate else { throw ExportError.nothingToExport }
            let source = try stage(candidate, in: scratch)
            let frames = try animationFrames(from: source)
            try encode(frames: frames, to: destination)
            try verifyNonEmpty(destination)
            return ExportOutcome(url: destination, strategy: plan.strategy,
                                 fidelity: plan.fidelity, reencoded: true,
                                 warnings: plan.warnings)

        case .encodeStill:
            guard let candidate = plan.candidate else { throw ExportError.nothingToExport }
            let source = try stage(candidate, in: scratch)
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw ExportError.decodeFailed(source.lastPathComponent)
            }
            let frame = TimedFrame(image: image, duration: stillDuration)
            try encode(frames: [frame], to: destination)
            try verifyNonEmpty(destination)
            return ExportOutcome(url: destination, strategy: plan.strategy,
                                 fidelity: plan.fidelity, reencoded: true,
                                 warnings: plan.warnings)
        }
    }

    // MARK: Materialising original bytes

    /// Copy the candidate's original bytes to `target`, unchanged.
    func materialise(_ candidate: MediaCandidate, to target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try? fileManager.removeItem(at: target)

        switch candidate.origin {
        case .looseFile:
            guard let source = candidate.fileURL else { throw ExportError.nothingToExport }
            try fileManager.copyItem(at: source, to: target)

        case .packaged:
            guard let archiveURL = candidate.archiveURL, let entry = candidate.entry else {
                throw ExportError.nothingToExport
            }
            let archive = try PkgArchive.read(at: archiveURL)
            try archive.copy(entry: entry, to: target)

        case .texture:
            guard let archiveURL = candidate.archiveURL, let entry = candidate.entry,
                  let payload = candidate.payload else { throw ExportError.nothingToExport }
            // Copy only the payload's byte range out of the texture entry, so a
            // 4K video never has to be held in memory.
            let archive = try PkgArchive.read(at: archiveURL)
            try archive.copy(entry: entry, to: target, byteRange: payload.range)
        }
    }

    private func stage(_ candidate: MediaCandidate, in scratch: URL) throws -> URL {
        if candidate.origin == .looseFile, let url = candidate.fileURL { return url }
        let target = scratch.appendingPathComponent(
            UUID().uuidString + "." + candidate.fileExtension
        )
        try materialise(candidate, to: target)
        return target
    }

    private func verifyNonEmpty(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1024 else { throw ExportError.encodeFailed("the export was empty") }
    }

    // MARK: Animation decoding

    struct TimedFrame {
        let image: CGImage
        let duration: Double
    }

    func animationFrames(from url: URL) throws -> [TimedFrame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExportError.decodeFailed(url.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ExportError.decodeFailed("no frames") }

        var frames: [TimedFrame] = []
        frames.reserveCapacity(count)

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var delay = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] {
                let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
                let apng = png?[kCGImagePropertyAPNGDelayTime] as? Double
                delay = [unclamped, clamped, apng].compactMap { $0 }.first { $0 > 0 } ?? 0.1
            }
            // Browsers clamp absurdly short GIF delays; match that behaviour.
            frames.append(TimedFrame(image: image, duration: max(delay, 0.02)))
        }

        guard !frames.isEmpty else { throw ExportError.decodeFailed("no decodable frames") }
        return frames
    }

    // MARK: Encoding

    func encode(frames: [TimedFrame], to destination: URL) throws {
        guard let first = frames.first else { throw ExportError.nothingToExport }

        // H.264 requires even dimensions.
        let width = max(2, first.image.width - (first.image.width % 2))
        let height = max(2, first.image.height - (first.image.height % 2))

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw ExportError.encodeFailed("the video writer rejected its input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.encodeFailed(writer.error?.localizedDescription ?? "writer refused to start")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        var elapsed = CMTime.zero

        for frame in frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = makePixelBuffer(from: frame.image, pool: pool,
                                               width: width, height: height) else {
                writer.cancelWriting()
                throw ExportError.encodeFailed("could not prepare a frame")
            }
            guard adaptor.append(buffer, withPresentationTime: elapsed) else {
                writer.cancelWriting()
                throw ExportError.encodeFailed(
                    writer.error?.localizedDescription ?? "a frame was rejected"
                )
            }
            elapsed = CMTimeAdd(
                elapsed, CMTime(value: CMTimeValue(frame.duration * Double(timescale)),
                                timescale: timescale)
            )
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if writer.status != .completed {
            throw ExportError.encodeFailed(
                writer.error?.localizedDescription ?? "the video did not finish writing"
            )
        }
    }

    private func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool,
                                 width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
