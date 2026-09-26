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
        loading = true
        error = nil
        defer { loading = false }

        do {
            items = try await SteamWorkshopWebScraper.loadItems(url: workshopURL(query: query))
            if items.isEmpty {
                error = "Steam returned no Workshop items for this search."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setSubscribed(_ items: [WorkshopItem]) {
        self.items = items
        error = items.isEmpty ? "No subscribed Wallpaper Engine items were found. Sign in to Steam in the subscription page first." : nil
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
}

@MainActor
final class SteamWorkshopWebScraper: NSObject, WKNavigationDelegate {
    private static var active: SteamWorkshopWebScraper?

    private let webView: WKWebView
    private var continuation: CheckedContinuation<[WorkshopItem], Error>?
    private var finished = false

    private init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    static func loadItems(url: URL) async throws -> [WorkshopItem] {
        let scraper = SteamWorkshopWebScraper(url: url)
        active = scraper

        return try await withCheckedThrowingContinuation { continuation in
            scraper.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        (() => {
            const anchors = Array.from(document.querySelectorAll('a[href*="sharedfiles/filedetails/?id="]'));
            const seen = new Set();
            return anchors.map(a => {
                let href = a.href || '';
                let id = '';
                try { id = new URL(href).searchParams.get('id') || ''; } catch (_) {}
                const container = a.closest('.workshopItem, .workshopItemSubscription, .workshopItemPreview, .item') || a;
                const image = a.querySelector('img') || container.querySelector('img');
                const titleNode =
                    a.querySelector('.workshopItemTitle') ||
                    container.querySelector('.workshopItemTitle') ||
                    container.querySelector('.workshopItemTitle a') ||
                    a;
                return {
                    id,
                    title: (titleNode?.textContent || '').trim(),
                    href,
                    preview: image?.src || ''
                };
            }).filter(x => /^\\d+$/.test(x.id) && !seen.has(x.id) && (seen.add(x.id), true)).slice(0, 50);
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }

            guard let raw = result as? [[String: Any]] else {
                self.finish(.success([]))
                return
            }

            var items: [WorkshopItem] = []
            var seen = Set<String>()

            for value in raw {
                guard let id = value["id"] as? String,
                      let href = value["href"] as? String,
                      let pageURL = URL(string: href),
                      seen.insert(id).inserted else { continue }

                let title = (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let previewURL = (value["preview"] as? String).flatMap(URL.init(string))

                items.append(.init(
                    id: id,
                    title: title?.isEmpty == false ? title! : "Untitled",
                    previewURL: previewURL,
                    pageURL: pageURL
                ))
            }

            self.finish(.success(items))
        }
    }

    private func finish(_ result: Result<[WorkshopItem], Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        Self.active = nil

        switch result {
        case .success(let items):
            continuation?.resume(returning: items)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
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
                    let href = a.href || '';
                    let id = '';
                    try { id = new URL(href).searchParams.get('id') || ''; } catch (_) {}
                    const container = a.closest('.workshopItem, .workshopItemSubscription, .workshopItemPreview, .item') || a;
                    const titleNode = a.querySelector('.workshopItemTitle') || container.querySelector('.workshopItemTitle') || a;
                    const image = a.querySelector('img') || container.querySelector('img');
                    return {
                        id,
                        title: (titleNode?.textContent || '').trim(),
                        href,
                        preview: image?.src || ''
                    };
                }).filter(x => /^\\d+$/.test(x.id) && !seen.has(x.id) && (seen.add(x.id), true)).slice(0, 100);
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
