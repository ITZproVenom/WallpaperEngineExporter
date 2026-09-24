import Foundation
import UniformTypeIdentifiers
import AVFoundation
import Compression

enum ImportError: LocalizedError {
    case invalidProject
    case missingAssets
    case unsupportedType
    case accessDenied
    case unzipFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidProject:
            return "Invalid Project\n\nThe imported files don't appear to contain a valid Wallpaper Engine project."
        case .missingAssets:
            return "Missing Assets\n\nThis wallpaper is missing one or more required files."
        case .unsupportedType:
            return "Unsupported Wallpaper\n\nThis Wallpaper Engine type requires functionality that isn't available on iOS."
        case .accessDenied:
            return "Could not access the selected file."
        case .unzipFailed:
            return "Could not extract the archive. The file may be corrupt or password-protected."
        case .unknown(let msg):
            return msg
        }
    }
}

struct ImportResult: Sendable {
    var item: WorkshopItem
    var videoURL: URL?
    var projectRoot: URL
    var entryFile: String?
    var assetList: [String]
}

actor WallpaperImporter {
    static let shared = WallpaperImporter()

    private let videoExtensions = ["mp4", "mov", "m4v", "webm", "avi", "mkv", "mpg", "mpeg"]
    private let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tga"]

    func importFrom(url: URL) async throws -> ImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let dest = try copyToDocuments(url)
        var root = dest

        // Unzip if needed
        let ext = dest.pathExtension.lowercased()
        if ext == "zip" || ext == "pkg" {
            root = try await unzip(dest)
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)

        if !isDir.boolValue {
            // Single media file
            if videoExtensions.contains(root.pathExtension.lowercased()) {
                let size = fileSize(root)
                let item = WorkshopItem(
                    id: UUID().uuidString.prefix(12).description,
                    title: root.deletingPathExtension().lastPathComponent,
                    author: nil,
                    previewURL: nil,
                    description: nil,
                    fileSize: size,
                    type: .video,
                    tags: [],
                    timeCreated: Date(),
                    timeUpdated: Date(),
                    isSubscribed: false,
                    localPath: root,
                    availability: .readyToExport
                )
                return ImportResult(item: item, videoURL: root, projectRoot: root.deletingLastPathComponent(), entryFile: root.lastPathComponent, assetList: [root.lastPathComponent])
            }
            throw ImportError.invalidProject
        }

        // Directory — find project.json or media
        let analysis = try analyzeDirectory(root)
        return analysis
    }

    private func analyzeDirectory(_ root: URL) throws -> ImportResult {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let lowerContents = contents.map { $0.lowercased() }

        var type: WallpaperType = .unknown
        var title = root.lastPathComponent
        var workshopID: String?
        var entryFile: String?
        var previewName: String?
        var description: String?
        var tags: [String] = []

        if lowerContents.contains("project.json") {
            let projectURL = root.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = json["title"] as? String { title = t }
                if let d = json["description"] as? String { description = d }
                if let f = json["file"] as? String { entryFile = f }
                if let p = json["preview"] as? String { previewName = p }
                if let wid = json["workshopid"] as? String { workshopID = wid }
                else if let wid = json["workshopid"] as? Int { workshopID = String(wid) }
                if let tg = json["tags"] as? [String] { tags = tg }
                if let typeStr = (json["type"] as? String)?.lowercased() {
                    switch typeStr {
                    case "video": type = .video
                    case "scene": type = .scene
                    case "web": type = .web
                    case "application", "app": type = .application
                    default: break
                    }
                }
            }
        }

        // Collect assets recursively (limited depth)
        let assets = collectFiles(at: root, maxDepth: 4)
        let videoFiles = assets.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        let htmlFiles = assets.filter { $0.pathExtension.lowercased() == "html" }

        if type == .unknown {
            if !videoFiles.isEmpty && entryFile == nil {
                type = .video
            } else if !htmlFiles.isEmpty || (entryFile?.lowercased().hasSuffix(".html") == true) {
                type = .web
            } else if entryFile?.lowercased().hasSuffix(".json") == true || lowerContents.contains("scene.json") {
                type = .scene
            } else if !videoFiles.isEmpty {
                type = .video
            }
        }

        // Resolve video URL for export
        var videoURL: URL?
        if type == .video {
            if let entry = entryFile {
                let candidate = root.appendingPathComponent(entry)
                if fm.fileExists(atPath: candidate.path) && videoExtensions.contains(candidate.pathExtension.lowercased()) {
                    videoURL = candidate
                }
            }
            if videoURL == nil {
                videoURL = videoFiles.first
            }
        }

        // For application / scene: still surface any embedded videos as optional export path
        if videoURL == nil, let firstVideo = videoFiles.first {
            videoURL = firstVideo
        }

        var availability: WorkshopItem.AvailabilityStatus = .imported
        if type == .video, videoURL != nil {
            availability = .readyToExport
        } else if type == .application && videoURL == nil {
            availability = .unsupported
        } else if type == .web || type == .scene {
            availability = videoURL != nil ? .readyToExport : .imported
        }

        let size = directorySize(root)
        let item = WorkshopItem(
            id: workshopID ?? UUID().uuidString.prefix(12).description,
            title: title,
            author: nil,
            previewURL: previewName.map { root.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil },
            description: description,
            fileSize: size,
            type: type,
            tags: tags,
            timeCreated: Date(),
            timeUpdated: Date(),
            isSubscribed: false,
            localPath: videoURL ?? root,
            availability: availability
        )

        return ImportResult(
            item: item,
            videoURL: videoURL,
            projectRoot: root,
            entryFile: entryFile,
            assetList: assets.map { $0.lastPathComponent }
        )
    }

    private func collectFiles(at url: URL, maxDepth: Int, depth: Int = 0) -> [URL] {
        guard depth <= maxDepth else { return [] }
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var count = 0
        for case let fileURL as URL in enumerator {
            if count > 500 { break } // safety
            var isReg: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isReg), !isReg.boolValue {
                result.append(fileURL)
                count += 1
            }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
            }
        }
        return result
    }

    private func copyToDocuments(_ url: URL) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destDir = docs.appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    private func unzip(_ zipURL: URL) async throws -> URL {
        let destDir = zipURL.deletingPathExtension()
        try? FileManager.default.removeItem(at: destDir)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Use Foundation's built-in approach via Process is unavailable on iOS.
        // Minimal ZIP extraction for store-method and deflate using Compression framework is complex.
        // Prefer NSFileManager coordination with a simple approach: for iOS 18+ / use third-party free logic.
        // Here we implement a pragmatic path: if unzip fails, treat as invalid.

        // Simple ZIP local-file parser for common Wallpaper Engine zips (stored/deflated)
        try extractZip(zipURL, to: destDir)

        // If zip contained a single top-level folder, use that
        let children = (try? FileManager.default.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)) ?? []
        if children.count == 1, children[0].hasDirectoryPath {
            return children[0]
        }
        return destDir
    }

    /// Minimal ZIP extractor supporting stored and deflated entries (common WE packages).
    private func extractZip(_ zipURL: URL, to destDir: URL) throws {
        guard let data = try? Data(contentsOf: zipURL) else { throw ImportError.unzipFailed }
        var offset = 0
        let bytes = [UInt8](data)

        while offset + 30 <= bytes.count {
            // Local file header signature 0x04034b50
            let sig = UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) | (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
            if sig != 0x04034b50 { break }

            let compression = UInt16(bytes[offset+8]) | (UInt16(bytes[offset+9]) << 8)
            let compSize = Int(UInt32(bytes[offset+18]) | (UInt32(bytes[offset+19]) << 8) | (UInt32(bytes[offset+20]) << 16) | (UInt32(bytes[offset+21]) << 24))
            let uncompSize = Int(UInt32(bytes[offset+22]) | (UInt32(bytes[offset+23]) << 8) | (UInt32(bytes[offset+24]) << 16) | (UInt32(bytes[offset+25]) << 24))
            let nameLen = Int(UInt16(bytes[offset+26]) | (UInt16(bytes[offset+27]) << 8))
            let extraLen = Int(UInt16(bytes[offset+28]) | (UInt16(bytes[offset+29]) << 8))

            let nameStart = offset + 30
            guard nameStart + nameLen <= bytes.count else { throw ImportError.unzipFailed }
            let nameData = Data(bytes[nameStart..<nameStart+nameLen])
            guard let name = String(data: nameData, encoding: .utf8) else { throw ImportError.unzipFailed }

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compSize <= bytes.count else { throw ImportError.unzipFailed }

            let outURL = destDir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let compressed = Data(bytes[dataStart..<dataStart+compSize])
                let output: Data
                if compression == 0 {
                    output = compressed
                } else if compression == 8 {
                    // deflate — zlib raw
                    guard let inflated = inflate(compressed, expectedSize: uncompSize) else {
                        throw ImportError.unzipFailed
                    }
                    output = inflated
                } else {
                    // Unsupported method — skip
                    offset = dataStart + compSize
                    continue
                }
                try output.write(to: outURL)
            }
            offset = dataStart + compSize
        }
    }

    private func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize < 500_000_000 else { return nil }
        var dest = Data(count: expectedSize)
        let result: Bool = data.withUnsafeBytes { srcPtr in
            dest.withUnsafeMutableBytes { destPtr in
                guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let destBase = destPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                var srcSize = data.count
                var destSize = expectedSize
                let status = compression_decode_buffer(
                    destBase, destSize,
                    srcBase, srcSize,
                    nil,
                    COMPRESSION_ZLIB
                )
                return status > 0
            }
        }
        return result ? dest : nil
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
