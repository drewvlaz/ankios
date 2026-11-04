@testable import AnkiKit
import XCTest

/// Runs on macOS (`swift test`) against the real Rust backend.
final class AnkiKitTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ankikit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOpenEmptyCollectionAndListDecks() async throws {
        let backend = try AnkiBackend(preferredLanguages: ["en"])
        try await backend.openCollection(at: CollectionPaths(folder: folder))
        let decks = try await backend.deckList()
        XCTAssertEqual(decks.map(\.name), ["Default"])
        XCTAssertFalse(decks[0].hasDueCards)

        let reviewer = Reviewer(backend: backend, deckID: decks[0].id)
        try await reviewer.start()
        let next = try await reviewer.nextCard()
        XCTAssertNil(next.card)
        let undid = try await reviewer.undo()
        XCTAssertFalse(undid)

        try await backend.closeCollection()
    }

    func testBackendErrorsAreTyped() async throws {
        let backend = try AnkiBackend(preferredLanguages: ["en"])
        do {
            _ = try await backend.deckList()
            XCTFail("expected collection-not-open error")
        } catch let error as AnkiError {
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testPostProcessReplacesPlayMarkersAndTypeFields() {
        let html = CardHTML.postProcess("a [anki:play:q:1] b [[type:Back]] c")
        XCTAssertTrue(html.contains(#"href="anki-play:q:1""#), html)
        XCTAssertFalse(html.contains("[[type:"), html)
        XCTAssertFalse(html.contains("[anki:play"), html)
    }
}
