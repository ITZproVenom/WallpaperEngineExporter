import Foundation
import AVFoundation
import UIKit

@MainActor
final class ExportStore: ObservableObject {
    @Published private(set) var records: [ExportRecord] = []
    @Published var error: String?
    private let fm = FileManager.default

    init() { load() }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let destination = importsDirectory().appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: url, to: destination)
        }
    }

    func importedURLs() -> [URL] {
        (try? fm.contentsOfDirectory(at: importsDirectory(), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }) ?? []
    }

    func export(_ source: URL) async {
        do {
            guard let asset = try PackageInspector.assets(in: source).first else { throw ExportError.unsupported }
            let output = exportsDirectory().appendingPathComponent(
                "\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).mp4"
            )

            if ["MP4", "MOV", "M4V"].contains(asset.kind) {
                try await transcode(asset.url, to: output)
            } else {
                try await still(asset.url, to: output)
            }

            records.insert(
                ExportRecord(id: UUID(), name: output.deletingPathExtension().lastPathComponent,
                             filename: output.lastPathComponent, createdAt: Date()),
                at: 0
            )
            save()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func url(for record: ExportRecord) -> URL {
        exportsDirectory().appendingPathComponent(record.filename)
    }

    func delete(_ record: ExportRecord) {
        try? fm.removeItem(at: url(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    private func transcode(_ input: URL, to output: URL) async throws {
        let asset = AVAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed
        }
        exporter.outputURL = output
        exporter.outputFileType = .mp4

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: exporter.error ?? ExportError.failed)
                }
            }
        }
    }

    private func still(_ input: URL, to output: URL) async throws {
        guard let image = UIImage(contentsOfFile: input.path), let cg = image.cgImage else {
            throw ExportError.failed
        }

        let width = min(max(cg.width, 2), 4096)
        let height = min(max(cg.height, 2), 4096)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let inputWriter = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inputWriter)
        writer.add(inputWriter)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixel
        )
        guard let pixel else { throw ExportError.failed }

        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])

        for frame in 0..<90 {
            while !inputWriter.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }

        inputWriter.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failed }
    }

    private func baseDirectory() -> URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaForge", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func importsDirectory() -> URL {
        let url = baseDirectory().appendingPathComponent("Imports", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exportsDirectory() -> URL {
        let url = baseDirectory().appendingPathComponent("Exports", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifest() -> URL {
        baseDirectory().appendingPathComponent("exports.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifest()),
              let value = try? JSONDecoder().decode([ExportRecord].self, from: data) else { return }
        records = value
    }

    private func save() {
        try? JSONEncoder().encode(records).write(to: manifest(), options: .atomic)
    }
}
