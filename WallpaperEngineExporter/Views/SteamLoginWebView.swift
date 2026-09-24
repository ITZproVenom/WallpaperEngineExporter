import SwiftUI
import WebKit

/// In-app Steam OpenID login. Intercepts the HTTPS return_to navigation so
/// authentication works without relying on custom URL schemes (required for
/// LiveContainer / sideload environments where ASWebAuthenticationSession
/// callbacks often never reach the app).
struct SteamLoginWebView: View {
    @EnvironmentObject var auth: SteamAuthenticationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = auth.makeOpenIDLoginURL() {
                    SteamOpenIDWebViewRepresentable(
                        startURL: url,
                        onOpenIDCallback: { callbackURL in
                            auth.handleOpenIDCallbackURL(callbackURL)
                        },
                        onFail: { message in
                            auth.lastError = message
                            auth.cancelLoginWebView()
                        }
                    )
                } else {
                    Text("Could not build Steam login URL.")
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("Steam Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        auth.cancelLoginWebView()
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: auth.showLoginWebView) { _, show in
            if !show { dismiss() }
        }
        .onChange(of: auth.isAuthenticated) { _, ok in
            if ok { dismiss() }
        }
    }
}

struct SteamOpenIDWebViewRepresentable: UIViewRepresentable {
    let startURL: URL
    let onOpenIDCallback: (URL) -> Void
    let onFail: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenIDCallback: onOpenIDCallback, onFail: onFail)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onOpenIDCallback: (URL) -> Void
        let onFail: (String) -> Void
        weak var webView: WKWebView?
        private var didHandleCallback = false

        init(onOpenIDCallback: @escaping (URL) -> Void, onFail: @escaping (String) -> Void) {
            self.onOpenIDCallback = onOpenIDCallback
            self.onFail = onFail
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Custom scheme (if bridge HTML ever redirects)
            if url.scheme?.lowercased() == "wallpaperexporter" {
                if !didHandleCallback {
                    didHandleCallback = true
                    onOpenIDCallback(url)
                }
                decisionHandler(.cancel)
                return
            }

            // HTTPS OpenID return_to — capture query params even if page is text/plain
            if SteamAuthenticationService.isOpenIDReturnURL(url) {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let items = components.queryItems,
                   items.contains(where: { $0.name == "openid.claimed_id" }) {
                    if !didHandleCallback {
                        didHandleCallback = true
                        onOpenIDCallback(url)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Ignore cancellation errors from our own .cancel decisions
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if !didHandleCallback {
                onFail("Steam Login Failed\n\nPage failed to load.\n\(error.localizedDescription)")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if !didHandleCallback {
                onFail("Steam Login Failed\n\nCould not load Steam login page.\n\(error.localizedDescription)")
            }
        }
    }
}
