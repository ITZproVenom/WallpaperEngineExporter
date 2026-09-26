import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func download(_ text: String) {
        guard !downloading else { return }
        error = nil
        downloadedURL = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            error = "Paste a valid http:// or https:// download link."
            return
        }

        downloading = true
        progress = 0

        Task {
            do {
                let file = try await start(url)
                downloadedURL = file
            } catch {
                self.error = error.localizedDescription
            }
            downloading = false
        }
    }

    private func start(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        Task { @MainActor in
            self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let response = downloadTask.response as? HTTPURLResponse
            guard let status = response?.statusCode, (200..<300).contains(status) else {
                throw DownloadError.httpStatus(response?.statusCode ?? -1)
            }

            let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")
            let filename = Self.filename(from: disposition, fallback: downloadTask.originalRequest?.url?.lastPathComponent)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + filename)

            try FileManager.default.copyItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private static func filename(from disposition: String?, fallback: String?) -> String {
        if let disposition,
           let range = disposition.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
            let value = String(disposition[range])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: """))
            if !value.isEmpty { return value }
        }
        let name = fallback?.isEmpty == false ? fallback! : "wallpaper.download"
        return name.removingPercentEncoding ?? name
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Download failed with HTTP (code)."
        }
    }
}
