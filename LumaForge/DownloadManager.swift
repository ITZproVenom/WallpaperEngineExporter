import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    private static let serverURL = URL(string: "https://fswswvhpszebuxnloysy.supabase.co/functions/v1/lumaforge-workshop-resolver")!

    func download(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let id = Self.workshopID(from: url) else {
            error = "Paste a valid Steam Workshop link."
            return
        }
        Task { await downloadWorkshopItem(id: id) }
    }

    static func workshopID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              id.count >= 6,
              id.count <= 20,
              id.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return id
    }

    func downloadWorkshopItem(id: String) async {
        guard !downloading else { return }

        error = nil
        downloadedURL = nil
        downloading = true
        defer { downloading = false }

        do {
            let downloadURL = try await requestServerDownloadURL(for: id)
            await downloadFile(from: downloadURL)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func requestServerDownloadURL(for id: String) async throws -> URL {
        var components = URLComponents(url: Self.serverURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.serverUnavailable
        }

        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = payload["error"] as? String,
               !message.isEmpty {
                throw DownloadError.serverMessage(message)
            }
            throw DownloadError.serverHTTP(http.statusCode)
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = payload["download_url"] as? String,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadError.serverMessage("The server did not return a valid Workshop download.")
        }

        return url
    }

    private func downloadFile(from url: URL) async {
        do {
            var request = URLRequest(url: url)
            request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/octet-stream,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let filename = Self.filename(
                response: http,
                fallback: url.lastPathComponent.isEmpty ? "wallpaper.pkg" : url.lastPathComponent
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
    case serverUnavailable
    case serverHTTP(Int)
    case serverMessage(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "The LumaForge Workshop server is unavailable."
        case .serverHTTP(let code):
            return "The LumaForge Workshop server returned HTTP \(code)."
        case .serverMessage(let message):
            return message
        case .httpStatus(let code):
            return "Workshop file download failed with HTTP \(code)."
        }
    }
}
