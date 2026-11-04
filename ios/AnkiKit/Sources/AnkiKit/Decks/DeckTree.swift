import Foundation

/// One deck in the deck list, with today's due counts (children and daily
/// limits already applied by the backend).
public struct DeckNode: Identifiable, Hashable, Sendable {
    public let id: Int64
    /// Last component of the name, e.g. "Verbs" for "Spanish::Verbs".
    public let name: String
    public let level: Int
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let isFiltered: Bool
    public let isCollapsed: Bool
    public let children: [DeckNode]

    /// For `OutlineGroup` / `List(children:)`, which want nil for leaves.
    public var childrenOrNil: [DeckNode]? { children.isEmpty ? nil : children }

    public var hasDueCards: Bool { newCount + learnCount + reviewCount > 0 }

    init(_ node: Anki_Decks_DeckTreeNode) {
        id = node.deckID
        name = node.name
        level = Int(node.level)
        newCount = Int(node.newCount)
        learnCount = Int(node.learnCount)
        reviewCount = Int(node.reviewCount)
        isFiltered = node.filtered
        isCollapsed = node.collapsed
        children = node.children.map(DeckNode.init)
    }
}

extension AnkiBackend {
    static let defaultDeckID: Int64 = 1

    /// Top-level decks with counts as of `now`.
    ///
    /// Like desktop Anki, the built-in "Default" deck is hidden when it's empty
    /// and the user has other decks.
    public func deckList(now: Date = Date()) async throws -> [DeckNode] {
        var request = Anki_Decks_DeckTreeRequest()
        request.now = Int64(now.timeIntervalSince1970)
        let root = try await deckTree(request)
        let decks = root.children
        let filtered = decks.filter { node in
            !(node.deckID == Self.defaultDeckID
                && node.totalIncludingChildren == 0
                && node.children.isEmpty
                && decks.count > 1)
        }
        return filtered.map(DeckNode.init)
    }

    public func setDeckCollapsed(_ deckID: Int64, collapsed: Bool) async throws {
        var request = Anki_Decks_SetDeckCollapsedRequest()
        request.deckID = deckID
        request.collapsed = collapsed
        request.scope = .reviewer
        try await setDeckCollapsed(request)
    }
}
