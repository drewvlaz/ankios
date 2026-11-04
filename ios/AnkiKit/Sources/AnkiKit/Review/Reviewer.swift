import Foundation

public enum Rating: Int, CaseIterable, Sendable {
    case again, hard, good, easy

    var proto: Anki_Scheduler_CardAnswer.Rating {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }
}

public struct QueueCounts: Sendable, Equatable {
    public var new: Int
    public var learning: Int
    public var review: Int

    public enum Queue: Sendable { case new, learning, review }
}

/// A card ready to show: rendered HTML for both sides plus the scheduling data
/// needed to answer it.
public struct ReviewCard: Identifiable, Sendable {
    public var id: Int64 { card.id }
    public let question: RenderedSide
    public let answer: RenderedSide
    /// The notetype's CSS.
    public let css: String
    /// Template index; desktop adds `card{ord+1}` as a body class.
    public let ordinal: Int
    /// Which count this card belongs to, for highlighting.
    public let queue: QueueCounts.Queue
    /// Labels for Again/Hard/Good/Easy, e.g. ["<1m", "6m", "10m", "4d"].
    public let intervalLabels: [String]

    let card: Anki_Cards_Card
    let states: Anki_Scheduler_SchedulingStates
}

/// Drives a study session for one deck using the backend's v3 scheduler.
///
/// The backend owns the queue: after each answer we just ask it for the next
/// card again. That's how desktop Anki works, and it means learning steps,
/// burying siblings, daily limits and FSRS are all handled in Rust.
public struct Reviewer: Sendable {
    let backend: AnkiBackend
    public let deckID: Int64

    public init(backend: AnkiBackend, deckID: Int64) {
        self.backend = backend
        self.deckID = deckID
    }

    /// Select the deck; must be called before `nextCard()`.
    public func start() async throws {
        var deck = Anki_Decks_DeckId()
        deck.did = deckID
        try await backend.setCurrentDeck(deck)
    }

    /// The next card to study, or nil when done for today.
    public func nextCard() async throws -> (card: ReviewCard?, counts: QueueCounts) {
        var request = Anki_Scheduler_GetQueuedCardsRequest()
        request.fetchLimit = 1
        let queued = try await backend.getQueuedCards(request)
        let counts = QueueCounts(
            new: Int(queued.newCount),
            learning: Int(queued.learningCount),
            review: Int(queued.reviewCount)
        )
        guard let top = queued.cards.first else {
            return (nil, counts)
        }
        return (try await prepare(top), counts)
    }

    public func answer(_ card: ReviewCard, rating: Rating, timeTaken: TimeInterval, answeredAt: Date = Date()) async throws {
        var answer = Anki_Scheduler_CardAnswer()
        answer.cardID = card.card.id
        answer.currentState = card.states.current
        answer.newState = switch rating {
        case .again: card.states.again
        case .hard: card.states.hard
        case .good: card.states.good
        case .easy: card.states.easy
        }
        answer.rating = rating.proto
        answer.answeredAtMillis = Int64(answeredAt.timeIntervalSince1970 * 1000)
        // Desktop caps recorded time (deck option, default 60s) so a card left on
        // screen doesn't skew stats. We apply the default cap.
        answer.millisecondsTaken = UInt32(min(max(timeTaken, 0), 60) * 1000)
        try await backend.answerCard(answer)
    }

    /// Undo the last action. Returns false if there was nothing to undo.
    @discardableResult
    public func undo() async throws -> Bool {
        do {
            try await backend.undo()
            return true
        } catch let error as AnkiError where error.kind == .undoEmpty {
            return false
        }
    }

    public func buryCard(_ card: ReviewCard) async throws {
        try await buryOrSuspend(card, mode: .buryUser)
    }

    public func suspendCard(_ card: ReviewCard) async throws {
        try await buryOrSuspend(card, mode: .suspend)
    }

    private func buryOrSuspend(_ card: ReviewCard, mode: Anki_Scheduler_BuryOrSuspendCardsRequest.Mode) async throws {
        var request = Anki_Scheduler_BuryOrSuspendCardsRequest()
        request.cardIds = [card.card.id]
        request.mode = mode
        try await backend.buryOrSuspendCards(request)
    }

    private func prepare(_ queued: Anki_Scheduler_QueuedCards.QueuedCard) async throws -> ReviewCard {
        let rendered = try await backend.render(cardID: queued.card.id)
        let labels = try await backend.describeNextStates(queued.states).vals
        let queue: QueueCounts.Queue = switch queued.queue {
        case .new: .new
        case .learning: .learning
        case .review, .UNRECOGNIZED: .review
        }
        return ReviewCard(
            question: rendered.question,
            answer: rendered.answer,
            css: rendered.css,
            ordinal: Int(queued.card.templateIdx),
            queue: queue,
            intervalLabels: labels,
            card: queued.card,
            states: queued.states
        )
    }
}
