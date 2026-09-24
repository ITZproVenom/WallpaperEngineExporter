import Foundation
import Combine

@MainActor
final class SteamWorkshopService: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var isLoading = false
    @Published var searchResults: [WorkshopItem] = []
    @Published var lastError: String?

    private let storageKey = "imported_workshop_items"
    private let appID = 431960

    init() {
        loadPersisted()
    }

    func refreshLibrary(for steamID: String) async {
        // Direct listing of private subscriptions requires Steam Web API key + backend.
        // Public metadata for known IDs remains available via fetchItemMetadata.
        isLoading = false
        lastError = nil
    }

    func search(query: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = WorkshopURLParser.extractID(from: trimmed) {
            if let item = await fetchItemMetadata(id: id) {
                searchResults = [item]
            } else {
                searchResults = []
                lastError = "Could not load Workshop item \(id). It may be private or unavailable."
            }
            return
        }

        // Free-text Workshop search requires Steam Web API (IPublishedFileService/QueryFiles) with an API key.
        // Without a key we cannot perform server-side search from a pure client.
        searchResults = []
        lastError = "Text search requires a Steam Web API key. Paste a Workshop URL or ID instead."
    }

    func item(fromWorkshopURL urlString: String) async -> WorkshopItem? {
        guard let id = WorkshopURLParser.extractID(from: urlString) else { return nil }
        if let existing = items.first(where: { $0.id == id }) {
            return existing
        }
        return await fetchItemMetadata(id: id)
    }

    /// Fetch public Workshop item metadata from the Steam Community page (no API key).
    func fetchItemMetadata(id: String) async -> WorkshopItem? {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            return parseWorkshopHTML(html: html, id: id)
        } catch {
            return nil
        }
    }

    private func parseWorkshopHTML(html: String, id: String) -> WorkshopItem {
        let title = extractMeta(html, property: "og:title")
            ?? extractBetween(html, start: "<div class=\"workshopItemTitle\">", end: "</div>")
            ?? "Workshop Item \(id)"

        let image = extractMeta(html, property: "og:image")
        let description = extractMeta(html, property: "og:description")

        var author: String?
        if let range = html.range(of: "class=\"friendBlockContent\"") {
            let slice = String(html[range.upperBound...].prefix(200))
            author = slice.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }

        // Type heuristics from page text
        var type: WallpaperType = .unknown
        let lower = html.lowercased()
        if lower.contains("type:</") || lower.contains(">video<") {
            if lower.contains(">video<") || lower.contains("video wallpaper") { type = .video }
            else if lower.contains(">scene<") || lower.contains("scene wallpaper") { type = .scene }
            else if lower.contains(">web<") || lower.contains("web wallpaper") { type = .web }
            else if lower.contains(">application<") { type = .application }
        }

        return WorkshopItem(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author,
            previewURL: image.flatMap { URL(string: $0) },
            description: description,
            fileSize: nil,
            type: type,
            tags: [],
            timeCreated: nil,
            timeUpdated: nil,
            isSubscribed: false,
            localPath: nil,
            availability: .metadataOnly
        )
    }

    private func extractMeta(_ html: String, property: String) -> String? {
        let patterns = [
            "property=\"\(property)\" content=\"([^"]+)\"",
            "content=\"([^"]+)\" property=\"\(property)\""
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(match.range(at: 1), in: html) {
                return String(html[r])
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
            }
        }
        return nil
    }

    private func extractBetween(_ html: String, start: String, end: String) -> String? {
        guard let s = html.range(of: start) else { return nil }
        let rest = html[s.upperBound...]
        guard let e = rest.range(of: end) else { return nil }
        return String(rest[..<e.lowerBound])
    }

    func addImported(_ item: WorkshopItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
        persist()
    }

    func removeItem(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WorkshopItem].self, from: data) else {
            return
        }
        items = decoded
    }
}
