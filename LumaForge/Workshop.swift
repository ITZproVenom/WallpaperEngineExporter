import Foundation
import SwiftUI
import WebKit

@MainActor
final class WorkshopStore: ObservableObject {
    @Published private(set) var items: [WorkshopItem] = []
    @Published var query = ""
    @Published private(set) var loading = false
    @Published var error: String?
    private let appID = "431960"

    func search() async {
        await fetch(url: workshopURL(query: query))
    }

    func setSubscribed(_ items: [WorkshopItem]) {
        self.items = items
        error = items.isEmpty ? "No subscribed Wallpaper Engine items were found. Sign in to Steam in the subscription page first." : nil
    }

    private func fetch(url: URL) async {
        loading = true
        error = nil
        defer { loading = false }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WorkshopError.http
            }

            let html = String(decoding: data, as: UTF8.self)
            guard !html.localizedCaseInsensitiveContains("Please log in") else {
                throw WorkshopError.loginRequired
            }

            let parsed = parse(html)
            items = parsed
            if parsed.isEmpty {
                throw WorkshopError.noItems
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func workshopURL(query: String) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        c.queryItems = [
            .init(name: "appid", value: appID),
            .init(name: "section", value: "items"),
            .init(name: "numperpage", value: "30")
        ]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            c.queryItems?.append(.init(name: "searchtext", value: text))
        }
        return c.url!
    }

    private func parse(_ html: String) -> [WorkshopItem] {
        let pattern = #"(?i)(?:href|data-href)\s*=\s*["']([^"']*sharedfiles/filedetails/\?id=(\d+)[^"']*)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }

        var out: [WorkshopItem] = []
        var seen = Set<String>()

        for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let idRange = Range(match.range(at: 2), in: html),
                  let urlRange = Range(match.range(at: 1), in: html) else { continue }

            let id = String(html[idRange])
            guard seen.insert(id).inserted else { continue }

            var raw = String(html[urlRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\/", with: "/")
                .replacingOccurrences(of: "&quot;", with: """)

            if raw.hasPrefix("//") { raw = "https:" + raw }
            if raw.hasPrefix("/") { raw = "https://steamcommunity.com" + raw }

            guard let pageURL = URL(string: raw) else { continue }

            let ns = html as NSString
            let anchorStart = max(0, match.range.location - 800)
            let anchorEnd = min(ns.length, match.range.location + match.range.length + 1800)
            let window = ns.substring(with: NSRange(location: anchorStart, length: anchorEnd - anchorStart))

            let titlePattern = #"(?is)<a[^>]*(?:href|data-href)\s*=\s*["'][^"']*sharedfiles/filedetails/\?id=\d+[^"']*["'][^>]*>(.*?)</a>"#
            let title = (try? NSRegularExpression(pattern: titlePattern))
                .flatMap { $0.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) }
                .flatMap { Range($0.range(at: 1), in: window) }
                .map { String(window[$0]) }
                .map(Self.cleanHTML)
                ?? "Untitled"

            let previewPattern = #"https?://[^"'\s<>]+\.(?:jpg|jpeg|png|webp)(?:\?[^"'\s<>]*)?"#
            let preview = (try? NSRegularExpression(pattern: previewPattern, options: .caseInsensitive))
                .flatMap { $0.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) }
                .flatMap { Range($0.range, in: window) }
                .flatMap { URL(string: String(window[$0]).replacingOccurrences(of: "&amp;", with: "&")) }

            out.append(.init(
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                previewURL: preview,
                pageURL: pageURL
            ))

            if out.count == 50 { break }
        }

        return out
    }

    private static func cleanHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: """)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SteamSubscriptionsView: UIViewRepresentable {
    let steamID: String
    let onItems: ([WorkshopItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onItems: onItems)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        var components = URLComponents(
            string: "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/"
        )!
        components.queryItems = [
            .init(name: "appid", value: "431960"),
            .init(name: "browsefilter", value: "mysubscriptions"),
            .init(name: "sortmethod", value: "lastupdated"),
            .init(name: "numperpage", value: "30"),
            .init(name: "p", value: "1")
        ]
        webView.load(URLRequest(url: components.url!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onItems: ([WorkshopItem]) -> Void
        private var extractionInProgress = false

        init(onItems: @escaping ([WorkshopItem]) -> Void) {
            self.onItems = onItems
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !extractionInProgress else { return }
            extractionInProgress = true

            let script = """
            (() => {
                const anchors = Array.from(document.querySelectorAll('a[href*="sharedfiles/filedetails/?id="]'));
                const seen = new Set();
                return anchors.map(a => {
                    const href = a.href || '';
                    let id = '';
                    try { id = new URL(href).searchParams.get('id') || ''; } catch (_) {}
                    const container = a.closest('.workshopItemSubscription, .workshopItem, .workshopItemPreview') || a;
                    const titleNode = a.querySelector('.workshopItemTitle') || container.querySelector('.workshopItemTitle') || a;
                    const image = a.querySelector('img') || container.querySelector('img');
                    return {
                        id,
                        title: (titleNode?.textContent || '').trim(),
                        href,
                        preview: image?.src || ''
                    };
                }).filter(x => /^\d+$/.test(x.id) && !seen.has(x.id) && (seen.add(x.id), true)).slice(0, 100);
            })()
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                self.extractionInProgress = false
                guard let raw = result as? [[String: Any]] else { return }

                var items: [WorkshopItem] = []
                var seen = Set<String>()

                for value in raw {
                    guard let id = value["id"] as? String,
                          let href = value["href"] as? String,
                          let url = URL(string: href),
                          seen.insert(id).inserted else { continue }

                    let title = (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let preview = (value["preview"] as? String).flatMap(URL.init(string))

                    items.append(.init(
                        id: id,
                        title: title?.isEmpty == false ? title! : "Untitled",
                        previewURL: preview,
                        pageURL: url
                    ))
                }

                if !items.isEmpty {
                    Task { @MainActor in self.onItems(items) }
                }
            }
        }
    }
}

enum WorkshopError: LocalizedError {
    case http, loginRequired, noItems

    var errorDescription: String? {
        switch self {
        case .http:
            "Steam Workshop could not be reached."
        case .loginRequired:
            "Steam requires an authenticated Workshop session to show subscriptions."
        case .noItems:
            "Steam returned no Workshop items."
        }
    }
}
