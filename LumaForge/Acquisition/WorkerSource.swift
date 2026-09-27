import Foundation

/// An optional remote worker, for the one case a phone genuinely cannot handle:
/// recording a real-time scene wallpaper.
///
/// Disabled until a URL is configured in Settings, and it reports that honestly
/// instead of failing at conversion time.
struct WorkerSource: AcquisitionSource {
    let name = "Remote worker"
    let priority = 50
    let baseURL: URL?
    let apiKey: String?

    func capability() -> AcquisitionCapability {
        guard let baseURL else {
            return AcquisitionCapability(
                name: name, available: false,
                detail: "Not configured. A worker is only needed for real-time scene wallpapers.",
                requiresConfiguration: true
            )
        }
        return AcquisitionCapability(
            name: name, available: true,
            detail: "Configured: \(baseURL.host ?? baseURL.absoluteString)"
        )
    }

    private func authorised(_ request: inout URLRequest) {
        request.setValue("LumaForge-iOS/3.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Ask the worker for the item's package, so the same local pipeline can
    /// inspect it. Conversion decisions stay on-device.
    func acquire(workshopID: String, into directory: URL) async throws -> AcquiredContent {
        guard let baseURL else {
            throw AcquisitionError.unavailable("No worker URL is configured.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/packages/\(workshopID)"))
        authorised(&request)

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AcquisitionError.failed("The worker did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AcquisitionError.failed("The worker returned HTTP \(http.statusCode).")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(workshopID).pkg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        return AcquiredContent(workshopID: workshopID, root: destination, sourceName: name,
                               notes: ["Fetched from \(baseURL.host ?? "worker")"])
    }
}
