import Foundation

/// Reader for Wallpaper Engine `TEXV0005` textures.
///
///     "TEXV0005\0"
///     "TEXI0001\0"   uint32 format, flags, width, height, imageWidth, imageHeight
///     "TEXB000n\0"   container; header length differs per version
///     payload
///
/// The payload is GPU-compressed pixel data, a plain image, or - the case this
/// app cares about - a complete MP4 video stream. Video wallpapers keep their
/// original encoded video inside a texture, so those bytes are the finished
/// video and must be copied out untouched.
enum TexError: LocalizedError, Equatable {
    case notATexture
    case missingInfoChunk
    case missingContainerChunk
    case truncated

    var errorDescription: String? {
        switch self {
        case .notATexture: return "This file is not a Wallpaper Engine texture."
        case .missingInfoChunk: return "The texture has no image information block."
        case .missingContainerChunk: return "The texture has no data block."
        case .truncated: return "The texture is incomplete or damaged."
        }
    }
}

struct TexPayload: Sendable, Equatable {
    enum Kind: String, Sendable {
        case video, animation, image, raw

        /// Playable media, as opposed to pixel data needing a renderer.
        var isMedia: Bool { self == .video || self == .animation }
    }

    let kind: Kind
    let fileExtension: String
    /// Offset of the payload within the TEX file.
    let offset: Int
    let size: Int
    let width: Int
    let height: Int
    let format: Int

    var range: Range<Int> { offset..<(offset + size) }
}

struct TexTexture {
    static let magic = Data("TEXV0005\0".utf8)
    static let infoChunk = Data("TEXI0001\0".utf8)

    /// Signatures recognised at the very start of a payload.
    private static let signatures: [(marker: [UInt8], ext: String, kind: TexPayload.Kind)] = [
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "png", .image),
        ([0xFF, 0xD8, 0xFF], "jpg", .image),
        (Array("GIF89a".utf8), "gif", .animation),
        (Array("GIF87a".utf8), "gif", .animation),
        ([0x1A, 0x45, 0xDF, 0xA3], "webm", .video),
        (Array("RIFF".utf8), "webp", .image),
    ]

    /// Locate an ISOBMFF (MP4) stream by validating the box-length prefix that
    /// must precede `ftyp`. Searching for the four characters alone produces
    /// false positives inside compressed pixel data and yields corrupt output.
    static func isobmffOffset(in body: Data) -> Int? {
        let marker = Data("ftyp".utf8)
        var searchStart = body.startIndex

        while searchStart < body.endIndex {
            guard let hit = body.range(of: marker, in: searchStart..<body.endIndex)?.lowerBound
            else { return nil }
            let boxStart = hit - 4
            guard boxStart >= body.startIndex else {
                searchStart = hit + 4
                continue
            }
            let lengthBytes = body[boxStart..<(boxStart + 4)]
            let boxLength = Int(lengthBytes.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            })
            if boxLength >= 8, boxLength <= body.distance(from: boxStart, to: body.endIndex) {
                return body.distance(from: body.startIndex, to: boxStart)
            }
            searchStart = hit + 4
        }
        return nil
    }

    private static func containerOffset(in blob: Data) -> Int? {
        // (tag, bytes consumed by tag + version-specific sub-header)
        let variants: [(String, Int)] = [("TEXB0004", 9 + 8), ("TEXB0003", 9 + 4), ("TEXB0002", 9 + 4)]
        for (tag, headerLength) in variants {
            if let hit = blob.range(of: Data(tag.utf8))?.lowerBound {
                let start = blob.distance(from: blob.startIndex, to: hit) + headerLength
                return start <= blob.count ? start : nil
            }
        }
        return nil
    }

    /// Identify the payload without copying it.
    static func probe(_ blob: Data) throws -> TexPayload {
        guard blob.count > magic.count, blob.prefix(magic.count) == magic else {
            throw TexError.notATexture
        }
        guard let infoRange = blob.range(of: infoChunk) else { throw TexError.missingInfoChunk }

        let base = blob.distance(from: blob.startIndex, to: infoRange.lowerBound) + infoChunk.count
        guard base + 16 <= blob.count else { throw TexError.truncated }

        func uint32(at offset: Int) -> Int {
            let start = blob.index(blob.startIndex, offsetBy: offset)
            return Int(blob[start..<(start + 4)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
        }
        let format = uint32(at: base)
        let width = uint32(at: base + 8)
        let height = uint32(at: base + 12)

        guard let containerStart = containerOffset(in: blob) else {
            throw TexError.missingContainerChunk
        }
        let body = blob.subdata(in: containerStart..<blob.count)

        if let videoAt = isobmffOffset(in: body) {
            return TexPayload(kind: .video, fileExtension: "mp4",
                              offset: containerStart + videoAt, size: body.count - videoAt,
                              width: width, height: height, format: format)
        }

        let head = Array(body.prefix(96))
        for signature in signatures {
            if let hit = firstIndex(of: signature.marker, in: head), hit <= 64 {
                return TexPayload(kind: signature.kind, fileExtension: signature.ext,
                                  offset: containerStart + hit, size: body.count - hit,
                                  width: width, height: height, format: format)
            }
        }

        return TexPayload(kind: .raw, fileExtension: "bin", offset: containerStart,
                          size: body.count, width: width, height: height, format: format)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    /// Return the payload bytes exactly as stored.
    static func payloadData(_ blob: Data) throws -> Data {
        let payload = try probe(blob)
        guard payload.range.upperBound <= blob.count else { throw TexError.truncated }
        return blob.subdata(in: payload.range)
    }
}
