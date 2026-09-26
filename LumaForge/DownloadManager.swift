import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    func download(_ text: String) {
        guard let url = Self.validURL(text) else {
            error = "Paste a valid Steam Workshop link or download URL."
            return
        }
        Task { await downloadURL(url) }
    }

    func downloadWorkshopItem(id: String) async {
        guard !downloading else { return }
        error = nil
        downloadedURL = nil
        downloading = true
        defer { downloading = false }

        do {
            if let url = try await SteamWorkshopAPI.fileURL(for: id) {
                try await downloadURL(url, alreadyMarked: true)
                if downloadedURL != nil { return }
            }

            let resolved = try await SteamWorkshopAPI.resolvedDownloadURL(for: id)
            try await downloadURL(resolved, alreadyMarked: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func downloadURL(_ url: URL, alreadyMarked: Bool = false) async {
        if !alreadyMarked {
            downloading = true
            error = nil
            downloadedURL = nil
        }
        defer {
            if !alreadyMarked { downloading = false }
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")

            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let filename = Self.filename(
                response: http,
                fallback: url.lastPathComponent.isEmpty ? "wallpaper.download" : url.lastPathComponent
            )
            let safe = filename.replacingOccurrences(of: "/", with: "_")
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + safe)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            downloadedURL = destination
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func filename(response: HTTPURLResponse, fallback: String) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(
                of: #"filename="?([^";]+)"?"#,
                options: .regularExpression
           ) {
            let value = String(disposition[range])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return fallback.removingPercentEncoding ?? fallback
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case noDirectFile
    case resolverHTTP(Int)
    case resolverFailed
    case resolverMessage(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed with HTTP \(code)."
        case .noDirectFile:
            return "Steam did not expose a public file URL for this Workshop item."
        case .resolverHTTP(let code):
            return "Workshop resolver returned HTTP \(code)."
        case .resolverFailed:
            return "The Workshop download resolver returned no download URL."
        case .resolverMessage(let message):
            return message
        }
    }
}

enum SteamWorkshopAPI {
    struct Response: Decodable {
        struct Details: Decodable {
            let result: Int
            let file_url: String?
            let filename: String?
        }
        let publishedfiledetails: [Details]
    }

    struct Envelope: Decodable {
        let response: Response
    }

    static func fileURL(for id: String) async throws -> URL? {
        var request = URLRequest(
            url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let details = envelope.response.publishedfiledetails.first,
              details.result == 1 else {
            return nil
        }
        guard let value = details.file_url, !value.isEmpty else {
            return nil
        }
        return URL(string: value)
    }

    static func resolvedDownloadURL(for id: String) async throws -> URL {
        var components = URLComponents(
            string: "https://fswswvhpszebuxnloysy.supabase.co/functions/v1/lumaforge-workshop-resolver"
        )!
        components.queryItems = [URLQueryItem(name: "id", value: id)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.resolverFailed
        }

        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = payload["error"] as? String,
               !message.isEmpty {
                throw DownloadError.resolverMessage(message)
            }
            throw DownloadError.resolverHTTP(http.statusCode)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["download_url"] as? String,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadError.resolverFailed
        }

        return url
    }

}
