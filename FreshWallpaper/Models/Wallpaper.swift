import Foundation

struct Wallpaper: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let author: String
    let previewURL: URL?
    let workshopURL: URL
    let tags: [String]
}
