import SwiftUI
import WebKit

struct WebWallpaperPreviewView: UIViewRepresentable {
    let rootDirectory: URL
    let entryFile: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false

        let entry = rootDirectory.appendingPathComponent(entryFile)
        if FileManager.default.fileExists(atPath: entry.path) {
            webView.loadFileURL(entry, allowingReadAccessTo: rootDirectory)
        } else {
            // Fallback: index.html
            let index = rootDirectory.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                webView.loadFileURL(index, allowingReadAccessTo: rootDirectory)
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
