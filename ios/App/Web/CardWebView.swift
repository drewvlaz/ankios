import SwiftUI
import UIKit
import WebKit

/// Renders card HTML. Media is served from the collection's media folder via a
/// custom scheme, so the page never gets file:// access.
struct CardWebView: UIViewRepresentable {
    let html: String
    let mediaFolder: URL
    /// Tapped a replay button: ("q" or "a", tag index).
    let onPlay: (String, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(mediaFolder: mediaFolder), forURLScheme: MediaSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        // Cards can't run arbitrary network fetches against our scheme handler
        // from other origins, and we don't persist cookies/storage.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPlay = onPlay
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: URL(string: MediaSchemeHandler.baseURL))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var onPlay: ((String, Int) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            switch url.scheme {
            case "anki-play":
                // anki-play:q:0
                let parts = url.absoluteString.split(separator: ":")
                if parts.count == 3, let index = Int(parts[2]) {
                    onPlay?(String(parts[1]), index)
                }
                return .cancel
            case "http", "https":
                guard action.navigationType == .linkActivated else {
                    // Sub-frame loads (e.g. embedded iframes) are allowed.
                    return .allow
                }
                await UIApplication.shared.open(url)
                return .cancel
            default:
                return .allow
            }
        }
    }
}
