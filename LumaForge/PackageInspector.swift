import Foundation
import UIKit
import zlib

struct PackageAsset: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: String
}

enum PackageInspector {
    static func assets(in url: URL) throws -> [PackageAsset] {
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "mp4", "mov", "m4v"].contains(ext) {
            return [.init(url: url, kind: ext.uppercased())]
        }

        let data = try Data(contentsOf: url)

        // ZIP containers returned by some Workshop download providers.
        if isZip(data) {
            let extracted = try extractMediaFromZip(data)
            if !extracted.isEmpty { return extracted }
        }

        // Native Wallpaper Engine scene.pkg / PKGV#### package.
        if data.count >= 4, String(data: data.prefix(4), encoding: .ascii) == "PKGV" {
            let extracted = try extractWallpaperEnginePackage(data)
            if !extracted.isEmpty { return extracted }
        }

        // Some providers return raw media with no useful extension.
        let bytes = [UInt8](data)
        if let png = extractPNG(data, bytes: bytes) { return [png] }
        if let jpg = extractJPEG(data, bytes: bytes) { return [jpg] }

        throw ExportError.unsupported
    }

    // MARK: - Wallpaper Engine PKG

    private struct PKGEntry {
        let name: String
        let offset: Int
        let length: Int
    }

    private static func extractWallpaperEnginePackage(_ data: Data) throws -> [PackageAsset] {
        var cursor = 0

        guard let root = readLengthPrefixedString(data, cursor: &cursor),
              root.hasPrefix("PKGV") else {
            throw ExportError.unsupported
        }

        guard let count = readUInt32Safe(data, cursor: &cursor),
              count <= 1_000_000 else {
            throw ExportError.unsupported
        }

        var entries: [PKGEntry] = []
        entries.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let name = readLengthPrefixedString(data, cursor: &cursor),
                  let offset = readUInt32Safe(data, cursor: &cursor),
                  let length = readUInt32Safe(data, cursor: &cursor) else {
                throw ExportError.unsupported
            }

            let start = Int(offset)
            let size = Int(length)
            guard start >= 0, size >= 0 else { continue }

            entries.append(.init(name: name, offset: start, length: size))
        }

        let payloadOffset = cursor

        // Prefer a real video if the wallpaper is a video wallpaper.
        let videoEntries = entries.filter {
            let e = $0.name.lowercased()
            return e.hasSuffix(".mp4") || e.hasSuffix(".webm") || e.hasSuffix(".mov") || e.hasSuffix(".m4v")
        }

        for entry in videoEntries.sorted(by: { $0.length > $1.length }) {
            if let media = writeEntry(entry, from: data, payloadOffset: payloadOffset) {
                return [media]
            }
        }

        // Scene wallpapers store their visual content in TEX files.
        // Try larger textures first, because those are normally the source
        // resolution rather than thumbnails/mipmaps.
        let textureEntries = entries.filter { $0.name.lowercased().hasSuffix(".tex") }
            .sorted { $0.length > $1.length }

        var assets: [PackageAsset] = []
        for entry in textureEntries {
            guard let texData = entryData(entry, from: data, payloadOffset: payloadOffset) else { continue }
            if let asset = extractLargestTexture(texData, preferredName: entry.name) {
                assets.append(asset)
            }
            if assets.count >= 4 { break }
        }

        if !assets.isEmpty {
            return assets
        }

        // Last fallback: look for embedded standard image/video signatures
        // inside package entries with nonstandard extensions.
        for entry in entries.sorted(by: { $0.length > $1.length }) {
            guard let bytes = entryData(entry, from: data, payloadOffset: payloadOffset) else { continue }
            if let png = extractPNG(bytes, bytes: [UInt8](bytes)) { return [png] }
            if let jpg = extractJPEG(bytes, bytes: [UInt8](bytes)) { return [jpg] }
        }

        return []
    }

    private static func extractLargestTexture(_ data: Data, preferredName: String) -> PackageAsset? {
        guard data.count >= 32,
              String(data: data.prefix(4), encoding: .ascii) == "TEXV" else {
            return nil
        }

        guard let texb = data.range(of: Data("TEXB".utf8))?.lowerBound else {
            return nil
        }

        let width = Int(readUInt32(data, 0x22))
        let height = Int(readUInt32(data, 0x26))
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            return nil
        }

        var pos = texb
        let targetWidth = UInt32(width)
        let targetHeight = UInt32(height)

        guard let first = findUInt32Pair(data, width: targetWidth, height: targetHeight, from: pos) else {
            return nil
        }

        pos = first
        var currentWidth = width
        var currentHeight = height

        for _ in 0..<8 {
            guard pos + 20 <= data.count else { break }

            let w = Int(readUInt32(data, pos))
            let h = Int(readUInt32(data, pos + 4))
            guard w == currentWidth, h == currentHeight else { break }

            let size = Int(readUInt32(data, pos + 16))
            guard size > 0, pos + 20 + size <= data.count else { break }

            let payload = data.subdata(in: (pos + 20)..<(pos + 20 + size))

            if let image = decodeTexture(payload, width: w, height: h, name: preferredName) {
                return image
            }

            pos += 20 + size
            currentWidth = max(1, currentWidth / 2)
            currentHeight = max(1, currentHeight / 2)
        }

        return nil
    }

    private static func decodeTexture(_ payload: Data, width: Int, height: Int, name: String) -> PackageAsset? {
        let bytes = [UInt8](payload)

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return writeImageData(payload, extension: "png", kind: "PNG")
        }

        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return writeImageData(payload, extension: "jpg", kind: "JPG")
        }

        // Wallpaper Engine's common RAW TEX representation is RLE-compressed
        // BGRA. Convert it to a normal PNG that AVAssetWriter can consume.
        let expected = width * height * 4
        guard expected > 0, expected <= 16384 * 16384 * 4 else { return nil }

        let decoded = decompressRLE(payload, expectedSize: expected)
        guard decoded.count == expected else { return nil }

        var pixelData = decoded
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        let uiImage = UIImage(cgImage: image)
        guard let png = uiImage.pngData() else { return nil }

        return writeImageData(png, extension: "png", kind: "PNG")
    }

    private static func decompressRLE(_ data: Data, expectedSize: Int) -> Data {
        let bytes = [UInt8](data)
        var result = Data()
        result.reserveCapacity(expectedSize)

        var i = 0
        while i < bytes.count && result.count < expectedSize {
            let control = bytes[i]
            i += 1

            if control & 0x80 != 0 {
                let count = Int(control & 0x7F) + 1
                guard i < bytes.count else { break }
                let value = bytes[i]
                i += 1
                result.append(contentsOf: repeatElement(value, count: min(count, expectedSize - result.count)))
            } else {
                let count = Int(control) + 1
                let available = min(count, bytes.count - i, expectedSize - result.count)
                if available > 0 {
                    result.append(contentsOf: bytes[i..<(i + available)])
                    i += available
                }
            }
        }

        return result
    }

    // MARK: - ZIP

    private struct ZipEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        return b == [0x50, 0x4B, 0x03, 0x04] ||
               b == [0x50, 0x4B, 0x05, 0x06] ||
               b == [0x50, 0x4B, 0x07, 0x08]
    }

    private static func extractMediaFromZip(_ data: Data) throws -> [PackageAsset] {
        let entries = try zipEntries(data)
        let mediaExtensions: Set<String> = [
            "png", "jpg", "jpeg", "webp", "gif", "mp4", "mov", "m4v", "webm"
        ]

        let candidates = entries
            .filter { !$0.name.hasSuffix("/") }
            .filter {
                mediaExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased())
            }
            .sorted {
                mediaPriority($0.name) < mediaPriority($1.name)
            }

        var result: [PackageAsset] = []
        let limit = min(candidates.count, 12)

        for entry in candidates.prefix(limit) {
            guard let bytes = try? extract(entry, from: data), !bytes.isEmpty else { continue }

            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "bin" : ext))

            try bytes.write(to: output, options: .atomic)

            let kind: String
            switch ext {
            case "jpg", "jpeg": kind = "JPG"
            case "png": kind = "PNG"
            case "webp": kind = "WEBP"
            case "gif": kind = "GIF"
            case "mp4": kind = "MP4"
            case "mov": kind = "MOV"
            case "m4v": kind = "M4V"
            case "webm": kind = "WEBM"
            default: kind = ext.uppercased()
            }

            result.append(.init(url: output, kind: kind))
        }

        return result
    }

    private static func mediaPriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v") { return 10 }
        if lower.hasSuffix(".webm") { return 15 }
        if lower.hasSuffix(".png") { return 20 }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return 25 }
        if lower.hasSuffix(".webp") || lower.hasSuffix(".gif") { return 30 }
        if lower.contains("preview") || lower.contains("thumbnail") { return 80 }
        return 90
    }

    private static func zipEntries(_ data: Data) throws -> [ZipEntry] {
        guard let eocd = findSignature(0x06054B50, in: data) else {
            throw ExportError.unsupported
        }

        let count = Int(readUInt16(data, eocd + 10))
        let centralSize = Int(readUInt32(data, eocd + 12))
        let centralOffset = Int(readUInt32(data, eocd + 16))

        guard count >= 0, centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            throw ExportError.unsupported
        }

        var entries: [ZipEntry] = []
        var offset = centralOffset

        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  readUInt32(data, offset) == 0x02014B50 else { break }

            let method = readUInt16(data, offset + 10)
            let compressedSize = Int(readUInt32(data, offset + 20))
            let uncompressedSize = Int(readUInt32(data, offset + 24))
            let nameLength = Int(readUInt16(data, offset + 28))
            let extraLength = Int(readUInt16(data, offset + 30))
            let commentLength = Int(readUInt16(data, offset + 32))
            let localOffset = Int(readUInt32(data, offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { break }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            entries.append(.init(name: name, method: method, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localOffset: localOffset))

            offset = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func extract(_ entry: ZipEntry, from data: Data) throws -> Data {
        let offset = entry.localOffset
        guard offset + 30 <= data.count, readUInt32(data, offset) == 0x04034B50 else {
            throw ExportError.unsupported
        }

        let nameLength = Int(readUInt16(data, offset + 26))
        let extraLength = Int(readUInt16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { throw ExportError.unsupported }

        let compressed = data.subdata(in: start..<end)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ExportError.unsupported
        }
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        var output = Data(count: max(expectedSize, 1))
        var decodedSize = 0

        let result: Int32 = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: Bytef.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_STREAM_ERROR
                }

                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = destinationBase
                stream.avail_out = uInt(destination.count)

                let initResult = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                               Int32(MemoryLayout<z_stream>.size))
                guard initResult == Z_OK else { return initResult }

                let inflateResult = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)

                guard inflateResult == Z_STREAM_END else { return inflateResult }
                decodedSize = Int(stream.total_out)
                return Z_OK
            }
        }

        guard result == Z_OK, decodedSize > 0 else { throw ExportError.unsupported }
        output.count = decodedSize
        return output
    }

    // MARK: - Helpers

    private static func readLengthPrefixedString(_ data: Data, cursor: inout Int) -> String? {
        guard let length = readUInt32Safe(data, cursor: &cursor) else { return nil }
        let n = Int(length)
        guard n >= 0, cursor + n <= data.count else { return nil }

        let valueData = data.subdata(in: cursor..<(cursor + n))
        cursor += n
        return String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    private static func readUInt32Safe(_ data: Data, cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= data.count else { return nil }
        let value = readUInt32(data, cursor)
        cursor += 4
        return value
    }

    private static func entryData(_ entry: PKGEntry, from data: Data, payloadOffset: Int) -> Data? {
        let start = payloadOffset + entry.offset
        let end = start + entry.length
        guard start >= payloadOffset, end <= data.count, end >= start else { return nil }
        return data.subdata(in: start..<end)
    }

    private static func writeEntry(_ entry: PKGEntry, from data: Data, payloadOffset: Int) -> PackageAsset? {
        guard let bytes = entryData(entry, from: data, payloadOffset: payloadOffset) else { return nil }
        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        let kind = ext.uppercased()
        return writeImageOrVideo(bytes, extension: ext, kind: kind)
    }

    private static func writeImageOrVideo(_ data: Data, extension ext: String, kind: String) -> PackageAsset? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "bin" : ext))
        do {
            try data.write(to: output, options: .atomic)
            return .init(url: output, kind: kind)
        } catch {
            return nil
        }
    }

    private static func writeImageData(_ data: Data, extension ext: String, kind: String) -> PackageAsset? {
        writeImageOrVideo(data, extension: ext, kind: kind)
    }

    private static func findUInt32Pair(_ data: Data, width: UInt32, height: UInt32, from: Int) -> Int? {
        guard from >= 0, from + 8 <= data.count else { return nil }
        for i in from...(data.count - 8) {
            if readUInt32(data, i) == width && readUInt32(data, i + 4) == height {
                return i
            }
        }
        return nil
    }

    private static func extractPNG(_ data: Data, bytes: [UInt8]) -> PackageAsset? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8,
              let i = bytes.indices.first(where: { $0 + 8 <= bytes.count && Array(bytes[$0..<$0+8]) == signature }) else {
            return nil
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try? data.subdata(in: i..<bytes.count).write(to: output)
        return .init(url: output, kind: "PNG")
    }

    private static func extractJPEG(_ data: Data, bytes: [UInt8]) -> PackageAsset? {
        guard bytes.count > 3 else { return nil }

        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                try? data.subdata(in: i..<bytes.count).write(to: output)
                return .init(url: output, kind: "JPG")
            }
        }

        return nil
    }

    private static func findSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) where readUInt32(data, i) == signature {
            return i
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) |
        (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
