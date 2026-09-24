import Foundation
import Combine

@MainActor
final class SteamWorkshopService: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var isLoading = false
    @Published var searchResults: [WorkshopItem] = []
    @Published var lastError: String?

    private let appID = 431960 // Wallpaper Engine

    func refreshLibrary(for steamID: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Steam Web API for subscribed items requires an API key and proper auth.
        // Without a developer API key we cannot list private subscriptions from a pure client app.
        // This method therefore populates a sample set and documents the limitation.
        // Real production use would proxy through a backend that holds a Steam Web API key
        // and uses IPublishedFileService or similar with the user's SteamID.

        // For demonstration we keep the list empty and rely on Import + Paste Workshop URL.
        items = []
        lastError = nil
    }

    func search(query: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Public Workshop search is limited without an API key.
        // Users can still paste a Workshop URL.
        searchResults = []
    }

    func item(fromWorkshopURL urlString: String) -> WorkshopItem? {
        guard let id = WorkshopURLParser.extractID(from: urlString) else { return nil }
        return WorkshopItem(
            id: id,
            title: "Workshop Item \(id)",
            author: nil,
            previewURL: nil,
            description: nil,
            fileSize: nil,
            type: .unknown,
            tags: [],
            timeCreated: nil,
            timeUpdated: nil,
            isSubscribed: false,
            localPath: nil,
            availability: .metadataOnly
        )
    }

    func addImported(_ item: WorkshopItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
    }
}
