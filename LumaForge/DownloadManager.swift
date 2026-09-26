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
            guard let url = try await SteamWorkshopAPI.fileURL(for: id) else {
                throw DownloadError.noDirectFile
            }
            try await downloadURL(url, alreadyMarked: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func downloadURL(_ url: URL, alreadyMarked: Bool = false) async {
        if !alreadyMarked { downloading = true; error = nil; downloadedURL = nil }
        defer { if !alreadyMarked { downloading = false } }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let filename = Self.filename(response: http, fallback: url.lastPathComponent.isEmpty ? "wallpaper.download" : url.lastPathComponent)
            let safe = filename.replacingOccurrences(of: "/", with: "_")
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + safe)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            downloadedURL = destination
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func filename(response: HTTPURLResponse, fallback: String) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
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
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "Download failed with HTTP \(code)."
        case .noDirectFile: "Steam did not expose a direct file URL for this wallpaper. That item must be obtained through Steam Workshop first."
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

    struct Envelope: Decodable { let response: Response }

    static func fileURL(for id: String) async throws -> URL? {
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let details = envelope.response.publishedfiledetails.first, details.result == 1 else { return nil }
        guard let value = details.file_url, !value.isEmpty else { return nil }
        return URL(string: value)
    }
}
