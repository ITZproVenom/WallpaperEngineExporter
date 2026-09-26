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
    let workshopID: String
}
