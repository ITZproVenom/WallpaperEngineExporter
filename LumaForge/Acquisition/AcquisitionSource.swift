import Foundation

/// Acquisition answers one question: where are this Workshop item's real files?
///
/// It knows nothing about PKG, TEX, or video encoding, and the processing
/// pipeline knows nothing about Steam, imports, or workers. Adding a new way to
/// obtain files must never require changing the pipeline.
struct AcquisitionCapability: Sendable, Identifiable {
    let name: String
    let available: Bool
    let detail: String
    var requiresUserAction: Bool = false
    var requiresConfiguration: Bool = false

    var id: String { name }
}

struct AcquiredContent: Sendable {
    let workshopID: String?
    /// A `.pkg` file or a directory holding the item's files.
    let root: URL
    let sourceName: String
    var notes: [String] = []
}

enum AcquisitionError: LocalizedError {
    case unavailable(String)
    case notFound(String)
    case failed(String)
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .notFound(let detail), .failed(let detail):
            return detail
        case .allSourcesFailed(let attempts):
            return (["No source could supply this wallpaper:"] + attempts.map { "• \($0)" })
                .joined(separator: "\n")
        }
    }
}

protocol AcquisitionSource: Sendable {
    var name: String { get }
    /// Lower runs first. Sources preserving original files rank best.
    var priority: Int { get }
    func capability() -> AcquisitionCapability
    func acquire(workshopID: String, into directory: URL) async throws -> AcquiredContent
}

/// Tries sources in priority order and reports why each one declined.
struct AcquisitionRegistry: Sendable {
    private(set) var sources: [any AcquisitionSource]

    init(sources: [any AcquisitionSource] = []) {
        self.sources = sources.sorted { $0.priority < $1.priority }
    }

    func capabilities() -> [AcquisitionCapability] {
        sources.map { $0.capability() }
    }

    func acquire(workshopID: String, into directory: URL) async throws -> AcquiredContent {
        var attempts: [String] = []
        for source in sources {
            let capability = source.capability()
            guard capability.available else {
                attempts.append("\(source.name): \(capability.detail)")
                continue
            }
            do {
                return try await source.acquire(workshopID: workshopID, into: directory)
            } catch {
                attempts.append("\(source.name): \(error.localizedDescription)")
            }
        }
        throw AcquisitionError.allSourcesFailed(attempts)
    }
}
