import Foundation
import Combine

@MainActor
final class SteamWorkshopService: ObservableObject {
    static let appID = "431960"

    @Published var items: [WorkshopItem] = []
    @Published var isLoading = false
    @Published var searchResults: [WorkshopItem] = []
    @Published var lastError: String?

    private let storageKey = "imported_workshop_items"

    init() {
        loadPersisted()
    }

    /// Loads public Workshop subscriptions/owned items visible on Steam's community pages.
    /// This deliberately does not pretend that Steam's desktop Workshop package API is
    /// available to a third-party iOS app.
    func refreshLibrary(for steamID: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var ids: [String] = []
        var sawPage = false

        // Steam exposes a public-facing workshop page for a profile. When subscriptions
        // are visible, this returns the user's subscribed Wallpaper Engine items.
        let subscriptionBase = "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/"
        let subscriptionQueries = [
            ["appid": Self.appID, "browsefilter": "mysubscriptions", "sortmethod": "creationorder"],
            ["appid": Self.appID, "browsefilter": "mysubscriptions", "sortmethod": "lastupdated"]
        ]

        for query in subscriptionQueries {
            if let html = await fetchHTML(base: subscriptionBase, query: query) {
                sawPage = true
                ids.append(contentsOf: extractWorkshopIDs(from: html))
                if !ids.isEmpty { break }
            }
        }

        // Publicly visible authored items are useful as a fallback when Steam hides
        // subscriptions from the profile page.
        if ids.isEmpty {
            let authoredQuery = [
                "appid": Self.appID,
                "sortmethod": "creationorder",
                "p": "1",
                "numperpage": "50"
            ]
            if let html = await fetchHTML(base: subscriptionBase, query: authoredQuery) {
                sawPage = true
                ids.append(contentsOf: extractWorkshopIDs(from: html))
            }
        }

        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else {
            if !sawPage {
                lastError = "Could not reach Steam Workshop."
            } else {
                lastError = "Steam did not expose any public Wallpaper Engine Workshop items for this profile."
            }
            return
        }

        let fetched = await fetchItems(ids: uniqueIDs)
        let merged = fetched.map { mergeWithExisting($0) }

        let importedOnly = items.filter { item in
            item.localPath != nil && !merged.contains(where: { $0.id == item.id })
        }
        items = merged + importedOnly
        persist()
    }

    /// Searches Steam's public Workshop browse endpoint. No Steam Web API key is required.
    func search(query: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        if let id = WorkshopURLParser.extractID(from: trimmed) {
            if let item = await fetchItemMetadata(id: id) {
                searchResults = [mergeWithExisting(item)]
            } else {
                searchResults = []
                lastError = "Could not load Workshop item \(id). It may be private or unavailable."
            }
            return
        }

        guard let url = makeWorkshopBrowseURL(searchText: trimmed),
              let html = await fetchHTML(url: url) else {
            searchResults = []
            lastError = "Could not reach Steam Workshop search."
            return
        }

        let ids = Array(Set(extractWorkshopIDs(from: html)))
        guard !ids.isEmpty else {
            searchResults = []
            lastError = "No Workshop items matched “\(trimmed)”."
            return
        }

        searchResults = await fetchItems(ids: ids.prefix(30).map(String.init)).map(mergeWithExisting)
        if searchResults.isEmpty {
            lastError = "No Workshop metadata could be loaded for those results."
        }
    }

    func item(fromWorkshopURL urlString: String) async -> WorkshopItem? {
        guard let id = WorkshopURLParser.extractID(from: urlString) else { return nil }
        if let existing = items.first(where: { $0.id == id }) {
            return existing
        }
        guard let fetched = await fetchItemMetadata(id: id) else { return nil }
        return mergeWithExisting(fetched)
    }

    func fetchItemMetadata(id: String) async -> WorkshopItem? {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else {
            return nil
        }
        guard let html = await fetchHTML(url: url) else { return nil }
        return parseWorkshopHTML(html: html, id: id)
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
        searchResults.removeAll { $0.id == id }
        persist()
    }

    private func fetchItems(ids: [String]) async -> [WorkshopItem] {
        var result: [WorkshopItem] = []
        result.reserveCapacity(ids.count)

        for id in ids {
            if let item = await fetchItemMetadata(id: id) {
                result.append(item)
            }
        }
        return result
    }

    private func fetchHTML(base: String, query: [String: String]) async -> String? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        return await fetchHTML(url: url)
    }

    private func fetchHTML(url: URL) async -> String? {
        do {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            return html
        } catch {
            return nil
        }
    }

    private func makeWorkshopBrowseURL(searchText: String) -> URL? {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: Self.appID),
            URLQueryItem(name: "browsesort", value: "textsearch"),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "num_per_page", value: "30"),
            URLQueryItem(name: "searchtext", value: searchText)
        ]
        return components.url
    }

    private func extractWorkshopIDs(from html: String) -> [String] {
        let patterns = [
            #"sharedfiles/filedetails/\?id=(\d+)"#,
            #"publishedfileid[^0-9]{0,20}(\d{5,})"#,
            #"PublishedFileID[^0-9]{0,20}(\d{5,})"#
        ]

        var found = [String]()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: html) else { continue }
                found.append(String(html[r]))
            }
        }

        var unique: [String] = []
        var seen = Set<String>()
        for id in found where seen.insert(id).inserted {
            unique.append(id)
        }
        return unique
    }

    private func mergeWithExisting(_ incoming: WorkshopItem) -> WorkshopItem {
        guard let existing = items.first(where: { $0.id == incoming.id }) else {
            return incoming
        }

        return WorkshopItem(
            id: incoming.id,
            title: incoming.title.isEmpty ? existing.title : incoming.title,
            author: incoming.author ?? existing.author,
            previewURL: incoming.previewURL ?? existing.previewURL,
            description: incoming.description ?? existing.description,
            fileSize: incoming.fileSize ?? existing.fileSize,
            type: incoming.type == .unknown ? existing.type : incoming.type,
            tags: incoming.tags.isEmpty ? existing.tags : incoming.tags,
            timeCreated: incoming.timeCreated ?? existing.timeCreated,
            timeUpdated: incoming.timeUpdated ?? existing.timeUpdated,
            isSubscribed: incoming.isSubscribed || existing.isSubscribed,
            localPath: existing.localPath,
            availability: existing.localPath != nil ? existing.availability : incoming.availability
        )
    }

    private func parseWorkshopHTML(html: String, id: String) -> WorkshopItem {
        let title = extractMetaContent(html, property: "og:title")
            ?? extractBetween(html, start: "<div class=\"workshopItemTitle\">", end: "</div>")
            ?? "Workshop Item \(id)"

        let image = extractMetaContent(html, property: "og:image")
        let description = extractMetaContent(html, property: "og:description")

        var author: String?
        if let range = html.range(of: "class=\"friendBlockContent\"") {
            let slice = String(html[range.upperBound...].prefix(500))
            author = slice
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var type: WallpaperType = .unknown
        let lower = html.lowercased()
        if lower.contains("video wallpaper") || lower.contains("video_wallpaper") {
            type = .video
        } else if lower.contains("scene wallpaper") || lower.contains("scene_wallpaper") {
            type = .scene
        } else if lower.contains("web wallpaper") || lower.contains("web_wallpaper") {
            type = .web
        } else if lower.contains("application wallpaper") || lower.contains("application_wallpaper") {
            type = .application
        }

        return WorkshopItem(
            id: id,
            title: decodeHTMLEntities(title.trimmingCharacters(in: .whitespacesAndNewlines)),
            author: author,
            previewURL: image.flatMap { URL(string: $0) },
            description: description.map(decodeHTMLEntities),
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
        guard let propRange = html.range(of: "property=\"\(property)\"") else {
            return extractContentNearProperty(html, property: property)
        }
        let start = html.index(propRange.lowerBound, offsetBy: -100, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(propRange.upperBound, offsetBy: 250, limitedBy: html.endIndex) ?? html.endIndex
        return extractQuotedContent(from: String(html[start..<end]))
    }

    private func extractContentNearProperty(_ html: String, property: String) -> String? {
        guard let range = html.range(of: "property=\"\(property)\"") else { return nil }
        let start = html.index(range.lowerBound, offsetBy: -120, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(range.upperBound, offsetBy: 250, limitedBy: html.endIndex) ?? html.endIndex
        return extractQuotedContent(from: String(html[start..<end]))
    }

    private func extractQuotedContent(from window: String) -> String? {
        guard let contentKey = window.range(of: "content=\"") else { return nil }
        let after = window[contentKey.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<endQuote])
    }

    private func extractBetween(_ html: String, start: String, end: String) -> String? {
        guard let s = html.range(of: start) else { return nil }
        let rest = html[s.upperBound...]
        guard let e = rest.range(of: end) else { return nil }
        return String(rest[..<e.lowerBound])
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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
