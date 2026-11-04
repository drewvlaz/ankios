import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `anki-media://media/<filename>` from the collection's media folder.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "anki-media"
    static let baseURL = "anki-media://media/"

    private let mediaFolder: URL

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let fileURL = resolve(url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Media filenames are flat (Anki forbids path separators), so anything
    /// that isn't a single path component is rejected.
    private func resolve(_ url: URL) -> URL? {
        // `path` is percent-decoded, which is what we want for names with
        // spaces or non-ASCII characters.
        let name = String(url.path.drop(while: { $0 == "/" }))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let file = mediaFolder.appendingPathComponent(name).standardizedFileURL
        guard file.deletingLastPathComponent() == mediaFolder else { return nil }
        return file
    }
}
