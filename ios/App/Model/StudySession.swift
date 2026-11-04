import AnkiKit
import Foundation
import Observation

/// State for one study session. The backend decides what comes next; this
/// only tracks what's on screen.
@MainActor
@Observable
final class StudySession {
    enum State {
        case loading
        case question(ReviewCard)
        case answer(ReviewCard)
        case finished
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var counts = QueueCounts(new: 0, learning: 0, review: 0)
    private(set) var canUndo = false

    private let reviewer: Reviewer
    private var shownAt = Date()
    private var isBusy = false

    init(backend: AnkiBackend, deckID: Int64) {
        reviewer = Reviewer(backend: backend, deckID: deckID)
    }

    var currentCard: ReviewCard? {
        switch state {
        case let .question(card), let .answer(card): card
        default: nil
        }
    }

    func start() async {
        do {
            try await reviewer.start()
            await loadNext()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func revealAnswer() {
        guard case let .question(card) = state else { return }
        state = .answer(card)
    }

    func answer(_ rating: Rating) async {
        guard case let .answer(card) = state, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await reviewer.answer(card, rating: rating, timeTaken: Date().timeIntervalSince(shownAt))
            canUndo = true
            await loadNext()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func undo() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            canUndo = try await reviewer.undo()
            await loadNext()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func bury() async { await act { try await self.reviewer.buryCard($0) } }
    func suspend() async { await act { try await self.reviewer.suspendCard($0) } }

    private func act(_ action: (ReviewCard) async throws -> Void) async {
        guard let card = currentCard, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action(card)
            canUndo = true
            await loadNext()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadNext() async {
        do {
            let next = try await reviewer.nextCard()
            counts = next.counts
            if let card = next.card {
                shownAt = Date()
                state = .question(card)
            } else {
                state = .finished
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
