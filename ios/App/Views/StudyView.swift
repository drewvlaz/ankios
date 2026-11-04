import AnkiKit
import SwiftUI

struct StudyView: View {
    let deck: DeckNode

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var session: StudySession?
    @State private var audio = AudioPlayer()

    var body: some View {
        VStack(spacing: 0) {
            CountsView(
                new: session?.counts.new ?? 0,
                learning: session?.counts.learning ?? 0,
                review: session?.counts.review ?? 0,
                highlight: session?.currentCard?.queue
            )
            .padding(.vertical, 6)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let session {
                controls(session)
                    .padding()
                    .background(.bar)
            }
        }
        .navigationTitle(deck.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await session?.undo() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!(session?.canUndo ?? false))

                Menu {
                    Button("Bury Card", systemImage: "eye.slash") { Task { await session?.bury() } }
                    Button("Suspend Card", systemImage: "pause.circle") { Task { await session?.suspend() } }
                    Button("Replay Audio", systemImage: "speaker.wave.2") { replayAudio() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(session?.currentCard == nil)
            }
        }
        .task {
            guard session == nil, let backend = model.backend else { return }
            let session = StudySession(backend: backend, deckID: deck.id)
            self.session = session
            await session.start()
        }
        .onChange(of: stateKey) { _, _ in autoplay() }
        .onDisappear {
            audio.stop()
            Task { await model.refreshDecks() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session?.state {
        case nil, .loading?:
            ProgressView()
        case let .question(card)?:
            cardView(card, html: card.question.html)
        case let .answer(card)?:
            cardView(card, html: card.answer.html)
        case .finished?:
            ContentUnavailableView(
                "Congratulations!",
                systemImage: "checkmark.circle",
                description: Text("You have finished this deck for now.")
            )
        case let .failed(message)?:
            ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private func cardView(_ card: ReviewCard, html: String) -> some View {
        CardWebView(
            html: CardHTML.document(
                body: html,
                css: card.css,
                ordinal: card.ordinal,
                nightMode: colorScheme == .dark,
                mediaBaseURL: MediaSchemeHandler.baseURL
            ),
            mediaFolder: model.paths.mediaFolder,
            onPlay: { side, index in play(card: card, side: side, index: index) }
        )
        .ignoresSafeArea(edges: .horizontal)
    }

    @ViewBuilder
    private func controls(_ session: StudySession) -> some View {
        switch session.state {
        case .question:
            Button {
                session.revealAnswer()
            } label: {
                Text("Show Answer").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        case let .answer(card):
            HStack(spacing: 8) {
                ForEach(Rating.allCases, id: \.self) { rating in
                    AnswerButton(
                        rating: rating,
                        interval: card.intervalLabels.indices.contains(rating.rawValue) ? card.intervalLabels[rating.rawValue] : ""
                    ) {
                        Task { await session.answer(rating) }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Audio

    /// Changes whenever a different side/card is shown.
    private var stateKey: String {
        switch session?.state {
        case let .question(card)?: "q\(card.id)"
        case let .answer(card)?: "a\(card.id)"
        default: ""
        }
    }

    private func autoplay() {
        audio.stop()
        switch session?.state {
        case let .question(card)?: audio.play(card.question.avTags, mediaFolder: model.paths.mediaFolder)
        case let .answer(card)?: audio.play(card.answer.avTags, mediaFolder: model.paths.mediaFolder)
        default: break
        }
    }

    private func replayAudio() { autoplay() }

    private func play(card: ReviewCard, side: String, index: Int) {
        let tags = side == "q" ? card.question.avTags : card.answer.avTags
        guard tags.indices.contains(index) else { return }
        audio.play([tags[index]], mediaFolder: model.paths.mediaFolder)
    }
}

private struct AnswerButton: View {
    let rating: Rating
    let interval: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(interval).font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private var title: String {
        switch rating {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    private var color: Color {
        switch rating {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}
