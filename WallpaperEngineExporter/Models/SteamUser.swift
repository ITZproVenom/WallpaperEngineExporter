import Foundation

struct SteamUser: Codable, Identifiable, Equatable {
    let steamID: String
    let displayName: String?
    let avatarURL: URL?
    let profileURL: URL?

    var id: String { steamID }
}
