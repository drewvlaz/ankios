import Foundation

/// A sound or TTS reference pulled out of card HTML.
public enum AVTag: Sendable, Equatable {
    /// A file in the media folder.
    case file(String)
    case tts(text: String, language: String, voices: [String], speed: Float)
}

public struct RenderedSide: Sendable {
    /// HTML with `[sound:...]` replaced by `<a href="anki-play:q:N">` buttons
    /// (N indexes `avTags`) and type-in-answer fields removed.
    public let html: String
    public let avTags: [AVTag]
}

public struct RenderedCard: Sendable {
    public let question: RenderedSide
    public let answer: RenderedSide
    public let css: String
}

extension AnkiBackend {
    public func render(cardID: Int64) async throws -> RenderedCard {
        var request = Anki_CardRendering_RenderExistingCardRequest()
        request.cardID = cardID
        let response = try await renderExistingCard(request)
        return RenderedCard(
            question: try await side(response.questionNodes, question: true),
            answer: try await side(response.answerNodes, question: false),
            css: response.css
        )
    }

    private func side(_ nodes: [Anki_CardRendering_RenderedTemplateNode], question: Bool) async throws -> RenderedSide {
        // With partial_render off every node is plain text; fall back to the
        // replacement's current text just in case.
        let raw = nodes.map { node -> String in
            switch node.value {
            case let .text(text)?: text
            case let .replacement(r)?: r.currentText
            case nil: ""
            }
        }.joined()

        var request = Anki_CardRendering_ExtractAvTagsRequest()
        request.text = raw
        request.questionSide = question
        let extracted = try await extractAvTags(request)

        let tags = extracted.avTags.compactMap { tag -> AVTag? in
            switch tag.value {
            case let .soundOrVideo(file)?: .file(file)
            case let .tts(t)?: .tts(text: t.fieldText, language: t.lang, voices: t.voices, speed: t.speed)
            case nil: nil
            }
        }
        return RenderedSide(html: CardHTML.postProcess(extracted.text), avTags: tags)
    }
}

/// HTML transforms the desktop reviewer does in Python/JS, reimplemented here.
public enum CardHTML {
    static func postProcess(_ html: String) -> String {
        var out = html
        // [anki:play:q:0] -> replay button
        if let play = try? Regex(#"\[anki:play:([qa]):(\d+)\]"#) {
            out = out.replacing(play) { match in
                let side = match.output[1].substring ?? "q"
                let index = match.output[2].substring ?? "0"
                return #"<a class="replay-button soundLink" href="anki-play:\#(side):\#(index)" aria-label="Play">\#(playIcon)</a>"#
            }
        }
        // Type-in-the-answer isn't supported yet; drop the placeholder rather
        // than showing raw template syntax.
        if let typeAnswer = try? Regex(#"\[\[type:[^\]]+\]\]"#) {
            out = out.replacing(typeAnswer, with: "")
        }
        return out
    }

    private static let playIcon = #"<svg class="playImage" viewBox="0 0 64 64" width="40" height="40"><circle cx="32" cy="32" r="29" fill="currentColor" opacity="0.15"/><path d="M26 20 L46 32 L26 44 Z" fill="currentColor"/></svg>"#

    /// A full document for a web view. `mediaBaseURL` is where relative
    /// `<img src="...">` resolve; the app serves it from the media folder.
    public static func document(body: String, css: String, ordinal: Int, nightMode: Bool, mediaBaseURL: String) -> String {
        // "mobile"/"iphone" match what AnkiMobile sets, so templates that already
        // special-case it keep working.
        let bodyClasses = ["card", "card\(ordinal + 1)", "mobile", "iphone"] + (nightMode ? ["nightMode", "night_mode"] : [])
        return """
        <!doctype html>
        <html class="\(nightMode ? "night-mode" : "")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <base href="\(mediaBaseURL)">
        <style>
        :root { color-scheme: \(nightMode ? "dark" : "light"); }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: 20px 16px 120px; overflow-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        /* Beats the template's plain `.card` colours but loses to its own
           `.nightMode.card` / `.night_mode` rules, which come later. */
        body.nightMode { background-color: #2c2c2c; color: #eeeeee; }
        .replay-button { display: inline-block; color: inherit; text-decoration: none; vertical-align: middle; }
        hr#answer { opacity: 0.4; }
        </style>
        <style>\(css)</style>
        </head>
        <body class="\(bodyClasses.joined(separator: " "))">
        <div id="qa">\(body)</div>
        </body>
        </html>
        """
    }
}
