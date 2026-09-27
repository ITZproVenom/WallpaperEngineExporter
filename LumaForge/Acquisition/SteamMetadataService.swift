import Foundation

/// Public Workshop metadata: no API key, no login.
///
/// This reveals whether an item is a Video, Scene, or Web wallpaper *before*
/// anything is downloaded, so the app can tell the user what fidelity to expect
/// up front. It does not return a download URL: `file_url` is always empty for
/// Wallpaper Engine, because Steam gates paid-app Workshop files on ownership.
struct WorkshopMetadata: Sendable, Identifiable, Hashable {
    let workshopID: String
    var title: String = ""
    var declaredType: String?
    var fileSize: Int = 0
    var tags: [String] = []
    var previewURL: URL?
    var resolution: String = ""
    var interactive: Bool = false

    var id: String { workshopID }

    /// Predicted, not promised: the package has the final say.
    var expectedFidelity: ExportFidelity {
        switch declaredType {
        case "Video": return .identical
        case "Scene", "Web", "Application": return .approximate
        default: return .none
        }
    }

    var expectationSummary: String {
        switch declaredType {
        case "Video":
            return "Video wallpaper — exports losslessly, no re-encoding."
        case "Scene":
            return interactive
                ? "Scene wallpaper, reacts while running — a video cannot reproduce that."
                : "Scene wallpaper — rendered in real time, so it needs a renderer."
        case "Web":
            return "Web wallpaper — rendered in real time, so it needs a renderer."
        case "Application":
            return "Application wallpaper — cannot be exported as video."
        default:
            return "Type unknown until the package is inspected."
        }
    }

    var formattedSize: String {
        guard fileSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

struct SteamMetadataService: Sendable {
    static let endpoint = URL(
        string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
    )!
    static let wallpaperEngineAppID = 431960
    static let typeTags: Set<String> = ["Video", "Scene", "Web", "Application"]
    static let interactiveTags: Set<String> = [
        "Audio responsive", "Interactive", "Clock", "Media Integration",
    ]

    func describe(workshopIDs: [String]) async throws -> [String: WorkshopMetadata] {
        guard !workshopIDs.isEmpty else { return [:] }

        var found: [String: WorkshopMetadata] = [:]
        for chunk in stride(from: 0, to: workshopIDs.count, by: 50).map({
            Array(workshopIDs[$0..<min($0 + 50, workshopIDs.count)])
        }) {
            var fields = ["itemcount=\(chunk.count)"]
            for (index, id) in chunk.enumerated() {
                fields.append("publishedfileids[\(index)]=\(id)")
            }
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded",
                             forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = fields.joined(separator: "&").data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw AcquisitionError.failed("Steam metadata lookup failed.")
            }
            for metadata in Self.parse(data) {
                found[metadata.workshopID] = metadata
            }
        }
        return found
    }

    func describe(workshopID: String) async throws -> WorkshopMetadata {
        guard let metadata = try await describe(workshopIDs: [workshopID])[workshopID] else {
            throw AcquisitionError.notFound("Workshop item \(workshopID) was not found.")
        }
        return metadata
    }

    static func parse(_ data: Data) -> [WorkshopMetadata] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let details = response["publishedfiledetails"] as? [[String: Any]]
        else { return [] }

        return details.compactMap { detail in
            guard let id = detail["publishedfileid"] as? String,
                  (detail["result"] as? Int) == 1 else { return nil }
            if let consumer = detail["consumer_app_id"] as? Int,
               consumer != wallpaperEngineAppID { return nil }

            let tags = (detail["tags"] as? [[String: Any]])?
                .compactMap { $0["tag"] as? String } ?? []
            let size = Int(detail["file_size"] as? String ?? "")
                ?? (detail["file_size"] as? Int ?? 0)

            return WorkshopMetadata(
                workshopID: id,
                title: detail["title"] as? String ?? "",
                declaredType: tags.first { typeTags.contains($0) },
                fileSize: size,
                tags: tags,
                previewURL: (detail["preview_url"] as? String).flatMap(URL.init(string:)),
                resolution: tags.first { $0.contains(" x ") } ?? "",
                interactive: tags.contains { interactiveTags.contains($0) }
            )
        }
    }
}
