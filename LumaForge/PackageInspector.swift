import Foundation
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

        // Wallpaper Engine downloads are commonly ZIP containers even when
        // the downloader gives them a generic or unusual filename.
        if isZip(data) {
            let extracted = try extractMediaFromZip(data)
            if !extracted.isEmpty { return extracted }
        }

        // Some providers return a raw media file with no useful extension.
        let bytes = [UInt8](data)
        if let png = extractPNG(data, bytes: bytes) { return [png] }
        if let jpg = extractJPEG(data, bytes: bytes) { return [jpg] }

        throw ExportError.unsupported
    }

    private static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        return b == [0x50, 0x4B, 0x03, 0x04] ||
               b == [0x50, 0x4B, 0x05, 0x06] ||
               b == [0x50, 0x4B, 0x07, 0x08]
    }

    private struct ZipEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
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
        if lower.contains("project.json") { return 0 }
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

        guard count >= 0,
              centralOffset >= 0,
              centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            throw ExportError.unsupported
        }

        var entries: [ZipEntry] = []
        var offset = centralOffset

        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  readUInt32(data, offset) == 0x02014B50 else {
                break
            }

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

            entries.append(.init(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localOffset: localOffset
            ))

            offset = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func extract(_ entry: ZipEntry, from data: Data) throws -> Data {
        let offset = entry.localOffset
        guard offset + 30 <= data.count,
              readUInt32(data, offset) == 0x04034B50 else {
            throw ExportError.unsupported
        }

        let nameLength = Int(readUInt16(data, offset + 26))
        let extraLength = Int(readUInt16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize

        guard start >= 0, end <= data.count else {
            throw ExportError.unsupported
        }

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

        let result: Int32 = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: Bytef.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_STREAM_ERROR
                }

                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = destinationBase
                stream.avail_out = uInt(output.count)

                let initResult = inflateInit2_(
                    &stream,
                    -MAX_WBITS,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                )
                guard initResult == Z_OK else { return initResult }

                let inflateResult = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)

                guard inflateResult == Z_STREAM_END else {
                    return inflateResult
                }

                output.count = Int(stream.total_out)
                return Z_OK
            }
        }

        guard result == Z_OK, !output.isEmpty else {
            throw ExportError.unsupported
        }
        return output
    }

    private static func extractPNG(_ data: Data, bytes: [UInt8]) -> PackageAsset? {
        guard bytes.count >= 8 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard let i = bytes.indices.first(where: { $0 + 8 <= bytes.count && Array(bytes[$0..<$0+8]) == signature }) else {
            return nil
        }
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try? data.subdata(in: i..<bytes.count).write(to: u)
        return .init(url: u, kind: "PNG")
    }

    private static func extractJPEG(_ data: Data, bytes: [UInt8]) -> PackageAsset? {
        guard bytes.count > 3 else { return nil }
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                let u = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                try? data.subdata(in: i..<bytes.count).write(to: u)
                return .init(url: u, kind: "JPG")
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

    private static func adler32(compressed data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
