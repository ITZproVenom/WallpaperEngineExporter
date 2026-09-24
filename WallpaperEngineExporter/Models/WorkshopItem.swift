import Foundation

enum WallpaperType: String, Codable, CaseIterable {
    case video
    case scene
    case web
    case application
    case unknown

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .scene: return "Scene"
        case .web: return "Web"
        case .application: return "Application"
        case .unknown: return "Unknown"
        }
    }

    var isExportable: Bool {
        self == .video
    }
}

struct WorkshopItem: Identifiable, Codable, Equatable {
    let id: String               // Workshop file ID
    let title: String
    let author: String?
    let previewURL: URL?
    let description: String?
    let fileSize: Int64?
    let type: WallpaperType
    let tags: [String]
    let timeCreated: Date?
    let timeUpdated: Date?
    var isSubscribed: Bool
    var localPath: URL?          // after import
    var availability: AvailabilityStatus

    enum AvailabilityStatus: String, Codable {
        case metadataOnly
        case imported
        case readyToExport
        case unsupported
        case missingAssets
    }
}
