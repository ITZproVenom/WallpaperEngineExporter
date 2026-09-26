import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var downloadedURL: URL?
    @Published var error: String?

    private static let maxHTMLHops = 12

    func download(_ text: String) {
        guard let url = Self.validURL(text) else {
            error = "Paste a valid Steam Workshop link or download URL."
            return
        }

        if let id = Self.workshopID(from: url) {
            Task { await downloadWorkshopItem(id: id) }
        } else {
            Task { await downloadURL(url) }
        }
    }

    static func workshopID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              id.count >= 6,
              id.count <= 20,
              id.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return id
    }

    func downloadWorkshopItem(id: String) async {
        guard !downloading else { return }
        error = nil
        downloadedURL = nil
        downloading = true
        defer { downloading = false }

        do {
            if let url = try await SteamWorkshopAPI.fileURL(for: id) {
                await downloadURL(url, alreadyMarked: true)
                if downloadedURL != nil { return }
            }

            if let ggURL = try await SteamWorkshopAPI.ggNetworkDownloadURL(for: id) {
                await downloadURL(ggURL, alreadyMarked: true)
                if downloadedURL != nil { return }
            }

            let resolved = try await SteamWorkshopAPI.resolvedDownloadURL(for: id)
            await downloadURL(resolved, alreadyMarked: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func downloadURL(_ url: URL, alreadyMarked: Bool = false, hop: Int = 0, visited: Set<String> = []) async {
        if !alreadyMarked {
            downloading = true
            error = nil
            downloadedURL = nil
        }
        defer {
            if !alreadyMarked { downloading = false }
        }

        do {
            guard hop <= Self.maxHTMLHops else {
                throw DownloadError.tooManyRedirectPages
            }

            let normalizedURL = url.absoluteString
            guard !visited.contains(normalizedURL) else {
                throw DownloadError.redirectLoop
            }
            var nextVisited = visited
            nextVisited.insert(normalizedURL)

            var request = URLRequest(url: url)
            request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/octet-stream, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")

            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            if Self.looksLikeHTML(response: http, fileURL: temporaryURL) {
                let html = try String(contentsOf: temporaryURL, encoding: .utf8)
                let candidates = Self.extractDownloadCandidates(from: html, baseURL: http.url ?? url)

                guard let next = candidates.first else {
                    throw DownloadError.htmlWithoutDownload
                }

                try? FileManager.default.removeItem(at: temporaryURL)
                await downloadURL(next, alreadyMarked: true, hop: hop + 1, visited: nextVisited)
                return
            }

            let filename = Self.filename(
                response: http,
                fallback: url.lastPathComponent.isEmpty ? "wallpaper.download" : url.lastPathComponent
            )
            let safe = filename.replacingOccurrences(of: "/", with: "_")
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + safe)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            downloadedURL = destination
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func looksLikeHTML(response: HTTPURLResponse, fileURL: URL) -> Bool {
        if let type = response.mimeType?.lowercased(), type.contains("html") {
            return true
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 2048),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else {
            return false
        }

        return text.hasPrefix("<!doctype html") ||
               text.hasPrefix("<html") ||
               text.hasPrefix("<head") ||
               text.hasPrefix("<body") ||
               text.contains("<html") ||
               text.contains("<!doctype html")
    }

    static func extractDownloadCandidates(from html: String, baseURL: URL) -> [URL] {
        var scored: [(score: Int, url: URL)] = []
        var seen = Set<String>()

        func add(_ raw: String, score: Int) {
            let cleaned = decodeHTMLEntities(
                raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\/", with: "/")
            )

            guard !cleaned.isEmpty,
                  let url = URL(string: cleaned, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.absoluteString != baseURL.absoluteString,
                  seen.insert(url.absoluteString).inserted else { return }

            let lower = url.absoluteString.lowercased()
            var finalScore = score

            if ["pkg", "zip", "7z", "rar", "tar", "gz", "mp4", "webm", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                finalScore += 100
            }
            if lower.contains("download") || lower.contains("direct") || lower.contains("transmit") ||
                lower.contains("cdn") || lower.contains("file") {
                finalScore += 25
            }
            if lower.contains("steamcommunity.com") || lower.contains("steamworkshopdownloader") ||
                lower.contains("captcha") || lower.contains("cloudflare") {
                finalScore -= 20
            }

            scored.append((finalScore, url))
        }

        let attrPattern = #"(?:href|src|data-url|data-download-url|data-href|data-file|action)\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: attrPattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
                let raw = String(html[valueRange])
                let contextStart = html.index(valueRange.lowerBound, offsetBy: -180, limitedBy: html.startIndex) ?? html.startIndex
                let contextEnd = html.index(valueRange.upperBound, offsetBy: 180, limitedBy: html.endIndex) ?? html.endIndex
                let context = String(html[contextStart..<contextEnd]).lowercased()
                let score = context.contains("download") || context.contains("direct") || context.contains("transmit") ? 80 : 20
                add(raw, score: score)
            }
        }

        let absolutePattern = #"https?://[^"'<>\s]+"#
        if let regex = try? NSRegularExpression(pattern: absolutePattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let valueRange = Range(match.range, in: html) else { continue }
                let raw = String(html[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
                let lower = raw.lowercased()
                let score = lower.contains("download") || lower.contains("direct") ||
                    lower.contains("transmit") || lower.contains("cdn") || lower.contains("file") ? 60 : 5
                add(raw, score: score)
            }
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.url.absoluteString.count < $1.url.absoluteString.count
            }
            .map { $0.url }
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func filename(response: HTTPURLResponse, fallback: String) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(
                of: #"filename="?([^";]+)"?"#,
                options: .regularExpression
           ) {
            let value = String(disposition[range])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return fallback.removingPercentEncoding ?? fallback
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case noDirectFile
    case resolverHTTP(Int)
    case resolverFailed
    case resolverMessage(String)
    case htmlWithoutDownload
    case tooManyRedirectPages
    case redirectLoop

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed with HTTP \(code)."
        case .noDirectFile:
            return "Steam did not expose a public file URL for this Workshop item."
        case .resolverHTTP(let code):
            return "Workshop resolver returned HTTP \(code)."
        case .resolverFailed:
            return "The Workshop download resolver returned no download URL."
        case .resolverMessage(let message):
            return message
        case .htmlWithoutDownload:
            return "The Workshop downloader returned a webpage without a usable file link."
        case .tooManyRedirectPages:
            return "The Workshop downloader returned too many intermediate webpages."
        case .redirectLoop:
            return "The Workshop downloader entered a redirect loop."
        }
    }
}

enum SteamWorkshopAPI {
    struct Response: Decodable {
        struct Details: Decodable {
            let result: Int
            let file_url: String?
            let filename: String?
        }
        let publishedfiledetails: [Details]
    }

    struct Envelope: Decodable {
        let response: Response
    }

    static func fileURL(for id: String) async throws -> URL? {
        var request = URLRequest(
            url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let details = envelope.response.publishedfiledetails.first,
              details.result == 1 else {
            return nil
        }
        guard let value = details.file_url, !value.isEmpty else {
            return nil
        }
        return URL(string: value)
    }

    static func ggNetworkDownloadURL(for id: String) async throws -> URL? {
        let workshopURL = "https://steamcommunity.com/sharedfiles/filedetails/?id=" + id
        let ggPageURL = URL(string: "https://ggntw.com/steam/" + id)!
        let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        // GGNetwork's web client establishes a session before calling the API.
        // Do the same so Cloudflare/session cookies are available to the API request.
        var warmup = URLRequest(url: ggPageURL)
        warmup.httpMethod = "GET"
        warmup.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        warmup.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        warmup.setValue("https://ggntw.com/", forHTTPHeaderField: "Referer")
        _ = try? await URLSession.shared.data(for: warmup)

        var request = URLRequest(url: URL(string: "https://api.ggntw.com/steam.request")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://ggntw.com", forHTTPHeaderField: "Origin")
        request.setValue(ggPageURL.absoluteString, forHTTPHeaderField: "Referer")

        if let cookies = HTTPCookieStorage.shared.cookies(for: ggPageURL), !cookies.isEmpty {
            let header = cookies
                .map { $0.name + "=" + $0.value }
                .joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": workshopURL])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            func findURL(_ value: Any) -> URL? {
                if let string = value as? String,
                   let url = URL(string: string),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    return url
                }

                if let dictionary = value as? [String: Any] {
                    for key in ["download_url", "downloadUrl", "url", "link", "file", "download", "href"] {
                        if let child = dictionary[key], let url = findURL(child) {
                            return url
                        }
                    }
                    for child in dictionary.values {
                        if let url = findURL(child) {
                            return url
                        }
                    }
                }

                if let array = value as? [Any] {
                    for child in array {
                        if let url = findURL(child) {
                            return url
                        }
                    }
                }

                return nil
            }

            if let url = findURL(object) {
                return url
            }
        }

        // Older GGNetwork clients rely on the API's HTTP redirect rather than
        // a JSON body. URLSession follows that redirect automatically, so the
        // final response URL is the actual CDN/file URL in that case.
        if let finalURL = http.url,
           finalURL.host?.lowercased() != "api.ggntw.com",
           finalURL.absoluteString != request.url?.absoluteString {
            let mime = http.mimeType?.lowercased() ?? ""
            let isHTML = mime.contains("html") || mime.contains("json") ||
                mime.contains("javascript") || mime.hasPrefix("text/")
            if !isHTML {
                return finalURL
            }
        }

        return nil

        func findURL(_ value: Any) -> URL? {
            if let string = value as? String,
               let url = URL(string: string),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url
            }

            if let dictionary = value as? [String: Any] {
                for key in ["download_url", "downloadUrl", "url", "link", "file", "download", "href"] {
                    if let child = dictionary[key], let url = findURL(child) {
                        return url
                    }
                }
                for child in dictionary.values {
                    if let url = findURL(child) {
                        return url
                    }
                }
            }

            if let array = value as? [Any] {
                for child in array {
                    if let url = findURL(child) {
                        return url
                    }
                }
            }

            return nil
        }

        return findURL(object)
    }

    static func resolvedDownloadURL(for id: String) async throws -> URL {
        var components = URLComponents(
            string: "https://fswswvhpszebuxnloysy.supabase.co/functions/v1/lumaforge-workshop-resolver"
        )!
        components.queryItems = [URLQueryItem(name: "id", value: id)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("LumaForge/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.resolverFailed
        }

        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = payload["error"] as? String,
               !message.isEmpty {
                throw DownloadError.resolverMessage(message)
            }
            throw DownloadError.resolverHTTP(http.statusCode)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["download_url"] as? String,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadError.resolverFailed
        }

        return url
    }
}
