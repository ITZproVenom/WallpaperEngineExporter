import Foundation
import Combine

@MainActor
final class SteamWorkshopService: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var isLoading = false
    @Published var searchResults: [WorkshopItem] = []
    @Published var lastError: String?

    private let storageKey = "imported_workshop_items"

    init() {
        loadPersisted()
    }

    func refreshLibrary(for steamID: String) async {
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

    func fetchItemMetadata(id: String) async -> WorkshopItem? {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else {
            return nil
        }
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
        let title = extractMetaContent(html, property: "og:title")
            ?? extractBetween(html, start: "<div class=\"workshopItemTitle\">", end: "</div>")
            ?? "Workshop Item \(id)"

        let image = extractMetaContent(html, property: "og:image")
        let description = extractMetaContent(html, property: "og:description")

        var author: String?
        if let range = html.range(of: "class=\"friendBlockContent\"") {
            let slice = String(html[range.upperBound...].prefix(200))
            author = slice.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }

        var type: WallpaperType = .unknown
        let lower = html.lowercased()
        if lower.contains(">video<") || lower.contains("video wallpaper") {
            type = .video
        } else if lower.contains(">scene<") || lower.contains("scene wallpaper") {
            type = .scene
        } else if lower.contains(">web<") || lower.contains("web wallpaper") {
            type = .web
        } else if lower.contains(">application<") {
            type = .application
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

    private func extractMetaContent(_ html: String, property: String) -> String? {
        // Look for: property="og:title" content="..."
        let marker = "property=\"\(property)\""
        guard let propRange = html.range(of: marker) else {
            // Alternate order: content=... property=
            let alt = "property=\"\(property)\""
            _ = alt
            return extractContentNearProperty(html, property: property)
        }
        let windowStart = html.index(propRange.lowerBound, offsetBy: -80, limitedBy: html.startIndex) ?? html.startIndex
        let windowEnd = html.index(propRange.upperBound, offsetBy: 200, limitedBy: html.endIndex) ?? html.endIndex
        let window = String(html[windowStart..<windowEnd])
        return extractQuotedContent(from: window)
    }

    private func extractContentNearProperty(_ html: String, property: String) -> String? {
        guard let range = html.range(of: "property=\"\(property)\"") else { return nil }
        let start = html.index(range.lowerBound, offsetBy: -100, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(range.upperBound, offsetBy: 150, limitedBy: html.endIndex) ?? html.endIndex
        return extractQuotedContent(from: String(html[start..<end]))
    }

    private func extractQuotedContent(from window: String) -> String? {
        guard let contentKey = window.range(of: "content=\"") else { return nil }
        let after = window[contentKey.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        let value = String(after[..<endQuote])
        return value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
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
