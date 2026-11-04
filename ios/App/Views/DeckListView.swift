import AnkiKit
import SwiftUI

struct DeckListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @State private var studying: DeckNode?

    var body: some View {
        NavigationStack {
            List {
                if case let .syncing(detail) = model.syncStatus {
                    SyncBanner(detail: detail) { model.cancelSync() }
                } else if case let .failed(message) = model.syncStatus {
                    Label(message, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                if let media = model.mediaStatus {
                    Label(media, systemImage: "photo.on.rectangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if model.decks.isEmpty {
                        Text("No decks yet. Log in to download your collection.")
                            .foregroundStyle(.secondary)
                    }
                    OutlineGroup(model.decks, children: \.childrenOrNil) { deck in
                        DeckRow(deck: deck)
                            .contentShape(Rectangle())
                            .onTapGesture { studying = deck }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Decks")
            .refreshable { await model.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.credentials == nil || model.isSyncing)
                }
            }
            .navigationDestination(item: $studying) { deck in
                StudyView(deck: deck)
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .confirmationDialog(
                "Your collection has changed on both this device and the server in a way that can't be merged.",
                isPresented: Binding(
                    get: { model.pendingFullSync != nil },
                    set: { if !$0 { model.pendingFullSync = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Download from Server", role: .destructive) {
                    Task { await model.resolveFullSync(.download) }
                }
                Button("Upload to Server", role: .destructive) {
                    Task { await model.resolveFullSync(.upload) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download replaces this device's collection. Upload replaces the server's copy, and other devices will need a full download.")
            }
            .alert(
                "Message from server",
                isPresented: Binding(
                    get: { model.serverMessage != nil },
                    set: { if !$0 { model.serverMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(model.serverMessage ?? "")
            }
        }
    }
}

private struct DeckRow: View {
    let deck: DeckNode

    var body: some View {
        HStack {
            Text(deck.name)
                .foregroundStyle(deck.isFiltered ? .blue : .primary)
            Spacer()
            CountsView(new: deck.newCount, learning: deck.learnCount, review: deck.reviewCount)
        }
        .padding(.vertical, 2)
    }
}

struct CountsView: View {
    let new: Int
    let learning: Int
    let review: Int
    var highlight: QueueCounts.Queue?

    var body: some View {
        HStack(spacing: 10) {
            count(new, .blue, .new)
            count(learning, .red, .learning)
            count(review, .green, .review)
        }
        .font(.callout.monospacedDigit())
    }

    private func count(_ value: Int, _ color: Color, _ queue: QueueCounts.Queue) -> some View {
        Text("\(value)")
            .foregroundStyle(value > 0 ? color : .secondary.opacity(0.5))
            .underline(highlight == queue)
            .fontWeight(highlight == queue ? .bold : .regular)
            .frame(minWidth: 24, alignment: .trailing)
    }
}

private struct SyncBanner: View {
    let detail: String?
    let cancel: () -> Void

    var body: some View {
        HStack {
            ProgressView()
            VStack(alignment: .leading) {
                Text("Syncing…")
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", action: cancel).font(.footnote)
        }
    }
}
