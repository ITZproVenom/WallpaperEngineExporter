import Foundation
import UniformTypeIdentifiers
import AVFoundation

enum ImportError: LocalizedError {
    case invalidProject
    case missingAssets
    case unsupportedType
    case accessDenied
    case unknown

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
        case .unknown:
            return "An unknown error occurred while importing."
        }
    }
}

actor WallpaperImporter {
    static let shared = WallpaperImporter()

    func importFrom(url: URL) async throws -> WorkshopItem {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        // Copy into app sandbox for reliable access
        let dest = try copyToDocuments(url)

        let type = try detectType(at: dest)
        let title = dest.deletingPathExtension().lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0

        var availability: WorkshopItem.AvailabilityStatus = .imported
        if type == .video {
            availability = .readyToExport
        } else if type == .application {
            availability = .unsupported
        }

        return WorkshopItem(
            id: UUID().uuidString.prefix(12).description,
            title: title,
            author: nil,
            previewURL: nil,
            description: nil,
            fileSize: size,
            type: type,
            tags: [],
            timeCreated: Date(),
            timeUpdated: Date(),
            isSubscribed: false,
            localPath: dest,
            availability: availability
        )
    }

    private func copyToDocuments(_ url: URL) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("Imported").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    private func detectType(at url: URL) throws -> WallpaperType {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)

        if !isDir.boolValue {
            // Single file – check if it's a video
            let ext = url.pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext) {
                return .video
            }
            // Maybe a project.json or scene file
            if ext == "json" || ext == "pkg" || ext == "wp" {
                return try parseProjectJSON(url) ?? .unknown
            }
            return .unknown
        }

        // Directory – look for classic Wallpaper Engine layout
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []

        // project.json is the usual marker
        if contents.contains("project.json") {
            let projectURL = url.appendingPathComponent("project.json")
            return try parseProjectJSON(projectURL) ?? .unknown
        }

        // Video files directly
        if contents.contains(where: { ["mp4", "mov", "webm"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            return .video
        }

        // HTML for web wallpapers
        if contents.contains(where: { $0.lowercased().hasSuffix(".html") || $0.lowercased() == "index.html" }) {
            return .web
        }

        // Scene markers
        if contents.contains(where: { $0.lowercased().contains("scene") || $0.hasSuffix(".json") }) {
            return .scene
        }

        throw ImportError.invalidProject
    }

    private func parseProjectJSON(_ url: URL) throws -> WallpaperType? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Wallpaper Engine project.json typically has "type" or "contentrating" etc.
        if let typeStr = json["type"] as? String {
            switch typeStr.lowercased() {
            case "video": return .video
            case "scene": return .scene
            case "web": return .web
            case "application", "app": return .application
            default: break
            }
        }

        // Heuristics based on presence of keys
        if json["file"] != nil || json["video"] != nil {
            return .video
        }
        if json["general"] != nil || json["objects"] != nil {
            return .scene
        }
        return .unknown
    }
}
