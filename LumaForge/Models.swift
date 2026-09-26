import Foundation

struct WorkshopItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let previewURL: URL?
    let pageURL: URL
}

struct ExportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let filename: String
    let createdAt: Date
}

enum ExportError: LocalizedError {
    case unsupported
    case failed
    var errorDescription: String? {
        switch self { case .unsupported: "Unsupported Wallpaper Engine content."; case .failed: "The export failed." }
    }
}
