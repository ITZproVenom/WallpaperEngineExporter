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
        if items.isEmpty {
            error = "No subscribed Wallpaper Engine items were found."
        }
    }

    private func fetch(url: URL) async {
        loading = true
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
            guard !html.contains("Please log in") else { throw WorkshopError.loginRequired }
            let parsed = parse(html)
            items = parsed
            if parsed.isEmpty { throw WorkshopError.noItems }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func workshopURL(query: String) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        c.queryItems = [
            .init(name: "appid", value: appID),
            .init(name: "section", value: "items")
        ]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            c.queryItems?.append(.init(name: "searchtext", value: text))
        }
        return c.url!
    }

    private func parse(_ html: String) -> [WorkshopItem] {
        guard let re = try? NSRegularExpression(
            pattern: #"<a[^>]+href="([^"]*sharedfiles/filedetails/\?id=(\d+)[^"]*)"[^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        var out: [WorkshopItem] = []
        var seen = Set<String>()

        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let ir = Range(m.range(at: 2), in: html),
                  let hr = Range(m.range(at: 1), in: html) else { continue }

            let id = String(html[ir])
            guard seen.insert(id).inserted else { continue }

            let raw = String(html[hr]).replacingOccurrences(of: "&amp;", with: "&")
            guard let page = URL(string: raw.hasPrefix("http") ? raw : "https://steamcommunity.com\(raw)") else { continue }

            let title = String(html[tr])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let ns = html as NSString
            let start = max(0, m.range.location - 1500)
            let window = ns.substring(with: NSRange(
                location: start,
                length: min(ns.length - start, m.range.length + 2800)
            ))
            let p = try? NSRegularExpression(
                pattern: #"https?://[^"' ]+\.(?:jpg|jpeg|png|webp)"#,
                options: .caseInsensitive
            )
            let preview = p?
                .firstMatch(in: window, range: NSRange(window.startIndex..., in: window))
                .flatMap { Range($0.range, in: window) }
                .flatMap { URL(string: String(window[$0]).replacingOccurrences(of: "&amp;", with: "&")) }

            out.append(.init(
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                previewURL: preview,
                pageURL: page
            ))

            if out.count == 50 { break }
        }

        return out
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
        configuration.websiteDataStore = .default()
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
                const nodes = Array.from(document.querySelectorAll('[id^="Subscription"]'));
                const source = nodes.length ? nodes : Array.from(document.querySelectorAll('.workshopItemSubscriptionDetails'));
                const items = source.map(node => {
                    const titleNode = node.querySelector('.workshopItemTitle');
                    const linkNode = titleNode?.closest('a') || node.querySelector('a[href*="filedetails/?id="]');
                    const imageNode = node.querySelector('img.workshopItemPreviewImage');
                    const href = linkNode?.href || '';
                    const id = new URL(href).searchParams.get('id') || '';
                    return {
                        id: id,
                        title: (titleNode?.textContent || '').trim(),
                        href: href,
                        preview: imageNode?.src || ''
                    };
                }).filter(item => /^\\d+$/.test(item.id));
                return items;
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
                    let preview = (value["preview"] as? String).flatMap(URL.init(string:))

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
            "No Workshop items were found."
        }
    }
}
