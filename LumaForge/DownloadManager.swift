import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    func download(_ text: String) {
        guard !downloading else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            error = "Paste a valid http:// or https:// download link."
            return
        }

        error = nil
        downloadedURL = nil
        downloading = true

        Task {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else {
                    throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }

                let filename = Self.filename(
                    response: response,
                    fallback: url.lastPathComponent.isEmpty ? "wallpaper.download" : url.lastPathComponent
                )
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + filename)

                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                downloadedURL = destination
            } catch {
                self.error = error.localizedDescription
            }

            downloading = false
        }
    }

    private static func filename(response: HTTPURLResponse, fallback: String) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
            let value = String(disposition[range])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: """))
            if !value.isEmpty { return value }
        }
        return fallback.removingPercentEncoding ?? fallback
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed with HTTP (code)."
        }
    }
}
