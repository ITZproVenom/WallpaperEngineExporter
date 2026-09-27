import Foundation

/// Decides how a Wallpaper Engine package should be exported.
///
/// The package contents decide, never the Workshop tags. Tags describe what the
/// author claimed; they are used only to explain a result and to warn about
/// wallpapers that react at runtime and therefore cannot become a faithful
/// video.
enum ExportStrategy: String, Sendable {
    /// Original MP4/MOV copied byte for byte.
    case passthrough
    /// Original WebM/MKV copied byte for byte; iOS cannot play or re-wrap these.
    case preserveOriginal
    case encodeAnimation
    case encodeStill
    /// Real-time wallpaper: needs a renderer, which a phone cannot provide.
    case renderScene
    case unsupported
}

enum ExportFidelity: String, Sendable {
    case identical
    case nearIdentical
    case approximate
    case staticOnly
    case none

    var label: String {
        switch self {
        case .identical: return "Identical to the original"
        case .nearIdentical: return "Near-identical"
        case .approximate: return "Approximate"
        case .staticOnly: return "Still image only"
        case .none: return "Not exportable"
        }
    }
}

/// A concrete piece of media located inside a package.
struct MediaCandidate: Sendable {
    enum Origin: String, Sendable {
        case looseFile   // a plain file in the folder
        case packaged    // an entry inside a .pkg
        case texture     // a payload inside a .tex inside a .pkg
    }

    let origin: Origin
    var fileURL: URL?
    var archiveURL: URL?
    var entry: PkgEntry?
    var payload: TexPayload?
    var kind: TexPayload.Kind
    var fileExtension: String
    var size: Int
    var width: Int = 0
    var height: Int = 0

    var pixels: Int { width * height }
}

struct ExportPlan: Sendable {
    let strategy: ExportStrategy
    let fidelity: ExportFidelity
    let reason: String
    var declaredType: String?
    var candidate: MediaCandidate?
    var sceneRoot: URL?
    var warnings: [String] = []

    var isExportable: Bool {
        strategy != .unsupported && strategy != .renderScene
    }

    /// True when the export reuses the original encoded stream.
    var isLossless: Bool {
        strategy == .passthrough || strategy == .preserveOriginal
    }
}

struct PackageInspector {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    static let preserveExtensions: Set<String> = ["webm", "mkv"]
    static let animationExtensions: Set<String> = ["gif", "apng"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "bmp"]

    static let interactiveTags: Set<String> = [
        "Audio responsive", "Interactive", "Clock", "Media Integration",
    ]

    // MARK: Entry point

    static func inspect(at root: URL, tags: [String] = []) -> ExportPlan {
        let fileManager = FileManager.default
        var searchRoot = root
        var archives: [URL] = []

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return ExportPlan(strategy: .unsupported, fidelity: .none,
                              reason: "That location could not be read.")
        }

        if !isDirectory.boolValue {
            if root.pathExtension.lowercased() == "pkg" {
                archives = [root]
                searchRoot = root.deletingLastPathComponent()
            } else {
                searchRoot = root.deletingLastPathComponent()
            }
        } else {
            archives = allFiles(in: root).filter { $0.pathExtension.lowercased() == "pkg" }
                .sorted { fileSize($0) > fileSize($1) }
        }

        let project = loadProject(in: searchRoot, archives: archives)
        let declared = declaredType(project: project, tags: tags)
        let warnings = tags.filter { interactiveTags.contains($0) }.map {
            "Tagged “\($0)”: this wallpaper reacts while it runs, so a video cannot reproduce that."
        }

        var candidates: [MediaCandidate] = []
        if isDirectory.boolValue { candidates += looseMedia(in: root) }
        for archive in archives { candidates += packagedMedia(in: archive) }

        // Best available media, preferring real video, then resolution, then size.
        let playable = candidates.filter { $0.kind.isMedia }
        let best = playable.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .video }
            if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
            return lhs.size > rhs.size
        }.first

        if let media = best, media.kind == .video {
            let isPreserveOnly = preserveExtensions.contains(media.fileExtension)
            let where_ = media.origin == .texture ? " inside a .tex texture" : ""
            return ExportPlan(
                strategy: isPreserveOnly ? .preserveOriginal : .passthrough,
                fidelity: .identical,
                reason: isPreserveOnly
                    ? "This package holds a \(media.fileExtension.uppercased()) video\(where_). "
                      + "It is exported exactly as stored, with no re-encoding."
                    : "This package already holds the finished video\(where_). "
                      + "It is exported without re-encoding.",
                declaredType: declared, candidate: media, warnings: warnings
            )
        }

        if let media = best, media.kind == .animation {
            return ExportPlan(
                strategy: .encodeAnimation, fidelity: .nearIdentical,
                reason: "This package holds an animation, which is encoded to MP4 at its native frame rate.",
                declaredType: declared, candidate: media, warnings: warnings
            )
        }

        let sceneArchive = archives.first { archive in
            (try? PkgArchive.read(at: archive))?.containsSceneDefinition ?? false
        }
        if sceneArchive != nil || ["Scene", "Web", "Application"].contains(declared ?? "") {
            return ExportPlan(
                strategy: .renderScene, fidelity: .approximate,
                reason: "This is a real-time wallpaper. It contains no finished video, so a "
                      + "Wallpaper Engine renderer has to record it; a phone cannot do that.",
                declaredType: declared,
                sceneRoot: sceneArchive?.deletingLastPathComponent() ?? searchRoot,
                warnings: warnings
            )
        }

        if let still = candidates.filter({ $0.kind == .image })
            .sorted(by: { $0.pixels > $1.pixels || ($0.pixels == $1.pixels && $0.size > $1.size) })
            .first {
            return ExportPlan(
                strategy: .encodeStill, fidelity: .staticOnly,
                reason: "This package holds only a still image, so the export will not move.",
                declaredType: declared, candidate: still, warnings: warnings
            )
        }

        return ExportPlan(
            strategy: .unsupported, fidelity: .none,
            reason: "No video, animation, image, or scene data was found in this package.",
            declaredType: declared, warnings: warnings
        )
    }

    // MARK: Helpers

    private static func allFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func loadProject(in root: URL, archives: [URL]) -> [String: Any] {
        if let onDisk = allFiles(in: root).first(where: {
            $0.lastPathComponent.lowercased() == "project.json"
        }), let data = try? Data(contentsOf: onDisk),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        for archive in archives {
            guard let pkg = try? PkgArchive.read(at: archive),
                  let entry = pkg.entries.first(where: {
                      $0.lastPathComponent.lowercased() == "project.json"
                  }), entry.size < 4 << 20,
                  let data = try? pkg.data(for: entry),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return parsed
        }
        return [:]
    }

    private static func declaredType(project: [String: Any], tags: [String]) -> String? {
        if let raw = project["type"] as? String {
            let normalised = raw.lowercased()
            if ["video", "scene", "web", "application"].contains(normalised) {
                return normalised.capitalized
            }
        }
        return tags.first { ["Video", "Scene", "Web", "Application"].contains($0) }
    }

    private static func looseMedia(in root: URL) -> [MediaCandidate] {
        allFiles(in: root).compactMap { url in
            let suffix = url.pathExtension.lowercased()
            let kind: TexPayload.Kind
            if videoExtensions.contains(suffix) || preserveExtensions.contains(suffix) {
                kind = .video
            } else if animationExtensions.contains(suffix) {
                kind = .animation
            } else if imageExtensions.contains(suffix) {
                kind = .image
            } else {
                return nil
            }
            return MediaCandidate(origin: .looseFile, fileURL: url, kind: kind,
                                  fileExtension: suffix, size: fileSize(url))
        }
    }

    private static func packagedMedia(in archiveURL: URL) -> [MediaCandidate] {
        guard let archive = try? PkgArchive.read(at: archiveURL) else { return [] }
        var found: [MediaCandidate] = []

        for entry in archive.entries {
            let suffix = entry.suffix
            if videoExtensions.contains(suffix) || preserveExtensions.contains(suffix) {
                found.append(MediaCandidate(origin: .packaged, archiveURL: archiveURL,
                                            entry: entry, kind: .video,
                                            fileExtension: suffix, size: entry.size))
            } else if animationExtensions.contains(suffix) {
                found.append(MediaCandidate(origin: .packaged, archiveURL: archiveURL,
                                            entry: entry, kind: .animation,
                                            fileExtension: suffix, size: entry.size))
            }
        }

        // Video wallpapers store their encoded stream inside a texture.
        for entry in archive.entries(withSuffixes: ["tex"]) where entry.size >= 1024 {
            guard let blob = try? archive.data(for: entry),
                  let payload = try? TexTexture.probe(blob), payload.kind.isMedia
            else { continue }
            found.append(MediaCandidate(
                origin: .texture, archiveURL: archiveURL, entry: entry, payload: payload,
                kind: payload.kind, fileExtension: payload.fileExtension,
                size: payload.size, width: payload.width, height: payload.height
            ))
        }

        return found
    }
}
