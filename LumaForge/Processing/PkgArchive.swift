import Foundation

/// Reader for Wallpaper Engine `PKGV0022` archives.
///
/// Layout:
///
///     uint32   header field (typically 8)
///     char[4]  "PKGV"
///     char[4]  version, e.g. "0022"
///     uint32   entryCount
///     entryCount x:
///         uint32  nameLength
///         bytes   name (UTF-8, forward slashes)
///         uint32  offset, relative to the start of the data section
///         uint32  size
///     data section
///
/// Entries are read at their stated offsets rather than assumed to be stored
/// back to back, and payloads are streamed so a multi-gigabyte package never
/// has to fit in memory on a phone.
enum PkgError: LocalizedError, Equatable {
    case notAnArchive
    case truncated
    case implausible(String)
    case unsafeName(String)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file is not a Wallpaper Engine package."
        case .truncated:
            return "The package is incomplete or damaged."
        case .implausible(let detail):
            return "The package header is not valid: \(detail)."
        case .unsafeName(let name):
            return "The package contains an unsafe file path: \(name)."
        case .missingEntry(let name):
            return "The package does not contain \(name)."
        }
    }
}

struct PkgEntry: Hashable, Sendable {
    let name: String
    let offset: Int
    let size: Int

    var suffix: String { (name as NSString).pathExtension.lowercased() }
    var lastPathComponent: String { (name as NSString).lastPathComponent }
}

struct PkgArchive: Sendable {
    static let magic = Data("PKGV".utf8)
    static let maxNameLength = 512
    static let maxEntries = 100_000

    let url: URL
    let version: String
    let dataStart: Int
    let entries: [PkgEntry]

    // MARK: Reading

    static func read(at url: URL) throws -> PkgArchive {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var cursor = 0
        func take(_ count: Int) throws -> Data {
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw PkgError.truncated
            }
            cursor += count
            return chunk
        }
        func takeUInt32() throws -> Int {
            let raw = try take(4)
            return Int(raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        }

        _ = try takeUInt32()
        guard try take(4) == magic else { throw PkgError.notAnArchive }
        let version = String(decoding: try take(4), as: UTF8.self)
        let entryCount = try takeUInt32()
        guard entryCount > 0, entryCount <= maxEntries else {
            throw PkgError.implausible("entry count \(entryCount)")
        }

        var entries: [PkgEntry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let nameLength = try takeUInt32()
            guard nameLength > 0, nameLength <= maxNameLength else {
                throw PkgError.implausible("name length \(nameLength)")
            }
            let name = String(decoding: try take(nameLength), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            let offset = try takeUInt32()
            let size = try takeUInt32()
            entries.append(PkgEntry(name: name, offset: offset, size: size))
        }

        return PkgArchive(url: url, version: version, dataStart: cursor, entries: entries)
    }

    // MARK: Queries

    func entries(withSuffixes suffixes: Set<String>) -> [PkgEntry] {
        entries.filter { suffixes.contains($0.suffix) }
    }

    func entry(named name: String) -> PkgEntry? {
        let wanted = name.lowercased()
        return entries.first { $0.name.lowercased() == wanted }
    }

    var containsSceneDefinition: Bool {
        let names = Set(entries.map { $0.lastPathComponent.lowercased() })
        return !names.isDisjoint(with: ["scene.json", "project.json"])
    }

    // MARK: Payload access

    /// Read one entry fully. Intended for small entries such as `.tex` headers
    /// and `project.json`; use `copy(entry:to:)` for large media.
    func data(for entry: PkgEntry) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(dataStart + entry.offset))
        guard let chunk = try handle.read(upToCount: entry.size), chunk.count == entry.size else {
            throw PkgError.truncated
        }
        return chunk
    }

    /// Stream an entry to disk in 4 MB chunks, preserving its bytes exactly.
    @discardableResult
    func copy(entry: PkgEntry, to destination: URL, byteRange: Range<Int>? = nil) throws -> URL {
        let start = entry.offset + (byteRange?.lowerBound ?? 0)
        var remaining = byteRange.map { $0.count } ?? entry.size

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(dataStart + start))

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        while remaining > 0 {
            let wanted = min(4 << 20, remaining)
            guard let chunk = try reader.read(upToCount: wanted), !chunk.isEmpty else {
                throw PkgError.truncated
            }
            try writer.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        return destination
    }

    // MARK: Extraction

    /// Reject absolute paths, Windows drive letters, and `..` traversal.
    static func safeRelativePath(_ name: String) throws -> String {
        let normalised = name.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespaces)
        guard !normalised.isEmpty, !normalised.hasPrefix("/") else {
            throw PkgError.unsafeName(name)
        }
        let components = normalised.split(separator: "/").map(String.init)
            .filter { $0 != "" && $0 != "." }
        guard !components.isEmpty, !components.contains("..") else {
            throw PkgError.unsafeName(name)
        }
        guard !(components[0].contains(":")) else { throw PkgError.unsafeName(name) }
        return components.joined(separator: "/")
    }

    @discardableResult
    func extractAll(to directory: URL) throws -> [URL] {
        var written: [URL] = []
        for entry in entries {
            let relative = try PkgArchive.safeRelativePath(entry.name)
            let destination = directory.appendingPathComponent(relative)
            try copy(entry: entry, to: destination)
            written.append(destination)
        }
        return written
    }
}
