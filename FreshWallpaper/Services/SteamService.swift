import Foundation

struct SteamService {
    func search(query: String) async throws -> [Wallpaper] {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        components.queryItems = [URLQueryItem(name: "appid", value: "431960"), URLQueryItem(name: "searchtext", value: query)]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let html = String(decoding: data, as: UTF8.self)
        return parse(html: html)
    }

    private func parse(html: String) -> [Wallpaper] {
        let pattern = #"<a[^>]+href=\"https://steamcommunity.com/sharedfiles/filedetails/\?id=(\d+)\"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(30).compactMap { m in
            guard m.numberOfRanges > 2 else { return nil }
            let id = ns.substring(with: m.range(at: 1))
            let raw = ns.substring(with: m.range(at: 2))
            let title = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else { return nil }
            return Wallpaper(id: id, title: title, author: "Steam Workshop", previewURL: nil, workshopURL: url, tags: [])
        }
    }
}
