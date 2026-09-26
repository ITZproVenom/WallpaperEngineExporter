import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    // This is the API gateway URL, not a file host. The gateway queues work on
    // the SteamCMD/FFmpeg worker and returns only the finished MP4.
    private static let serverURL = URL(string: "https://lumaforge-worker.onrender.com")!

    func download(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let id = Self.workshopID(from: url) {
            Task { await downloadWorkshopItem(id: id) }
        } else if let id = Self.workshopID(from: trimmed) {
            Task { await downloadWorkshopItem(id: id) }
        } else {
            error = "Paste a valid Steam Workshop link or Workshop ID."
        }
    }

    static func workshopID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              isValidWorkshopID(id) else {
            return nil
        }
        return id
    }

    private static func isValidWorkshopID(_ id: String) -> Bool {
        id.count >= 6 && id.count <= 20 && id.allSatisfy(\.isNumber)
    }

    func downloadWorkshopItem(id: String) async {
        guard !downloading else { return }
        guard Self.isValidWorkshopID(id) else {
            error = "Invalid Steam Workshop ID."
            return
        }

        error = nil
        downloadedURL = nil
        progress = 0
        status = "Queuing server job…"
        downloading = true
        defer { downloading = false }

        do {
            let job = try await createJob(workshopID: id)
            try await poll(jobID: job.jobID)
        } catch is CancellationError {
            status = ""
        } catch {
            self.error = error.localizedDescription
            status = ""
        }
    }

    private func createJob(workshopID: String) async throws -> JobResponse {
        let url = Self.serverURL.appendingPathComponent("v1/jobs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LumaForge-iOS/2.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(CreateJobRequest(workshopID: workshopID))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        let job = try JSONDecoder().decode(JobResponse.self, from: data)
        guard !job.jobID.isEmpty else {
            throw DownloadError.serverMessage("The server did not return a job ID.")
        }
        return job
    }

    private func poll(jobID: String) async throws {
        var delay: UInt64 = 500_000_000

        for _ in 0..<360 {
            try Task.checkCancellation()

            let job = try await getJob(jobID: jobID)
            progress = min(max(Double(job.progress) / 100.0, 0), 1)

            switch job.status {
            case "queued":
                status = "Queued…"
            case "downloading":
                status = "Downloading on server…"
            case "converting":
                status = "Converting on server…"
            case "completed":
                guard let filename = job.filename, filename.hasSuffix(".mp4") else {
                    throw DownloadError.serverMessage("The server completed the job without an MP4.")
                }
                status = "Downloading finished MP4…"
                let url = try await downloadFinalMP4(jobID: jobID, filename: filename)
                downloadedURL = url
                progress = 1
                status = "Completed"
                return
            case "failed":
                throw DownloadError.serverMessage(job.error ?? "The server failed to process this Workshop item.")
            default:
                throw DownloadError.serverMessage("Unknown server job status: \(job.status)")
            }

            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 2_000_000_000)
        }

        throw DownloadError.serverMessage("The server job timed out while waiting for a result.")
    }

    private func getJob(jobID: String) async throws -> JobResponse {
        let url = Self.serverURL
            .appendingPathComponent("v1/jobs")
            .appendingPathComponent(jobID)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LumaForge-iOS/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(JobResponse.self, from: data)
    }

    private func downloadFinalMP4(jobID: String, filename: String) async throws -> URL {
        let url = Self.serverURL
            .appendingPathComponent("v1/files")
            .appendingPathComponent(filename)

        var request = URLRequest(url: url)
        request.setValue("video/mp4", forHTTPHeaderField: "Accept")
        request.setValue("LumaForge-iOS/2.0", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(jobID)-\(filename)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.serverUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(ServerError.self, from: data),
               !payload.error.isEmpty {
                throw DownloadError.serverMessage(payload.error)
            }
            throw DownloadError.serverHTTP(http.statusCode)
        }
    }
}

private struct CreateJobRequest: Encodable {
    let workshop_id: String

    init(workshopID: String) {
        self.workshop_id = workshopID
    }
}

private struct JobResponse: Decodable {
    let jobID: String
    let status: String
    let progress: Int
    let filename: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status, progress, filename, error
    }
}

private struct ServerError: Decodable {
    let error: String
}

enum DownloadError: LocalizedError {
    case serverUnavailable
    case serverHTTP(Int)
    case serverMessage(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "The LumaForge server is unavailable."
        case .serverHTTP(let code):
            return "The LumaForge server returned HTTP \(code)."
        case .serverMessage(let message):
            return message
        case .httpStatus(let code):
            return "The finished MP4 download failed with HTTP \(code)."
        }
    }
}
