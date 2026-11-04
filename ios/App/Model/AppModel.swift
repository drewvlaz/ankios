import AnkiKit
import Foundation
import Observation
import UIKit

/// App-wide state: the backend, the open collection, login and sync.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case starting
        case ready
        case failed(String)
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing(detail: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var credentials: SyncCredentials?
    private(set) var decks: [DeckNode] = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var mediaStatus: String?
    private(set) var lastSync: Date?
    /// Set when the server and device have diverged; the UI must ask the user
    /// which side wins. Holds the server media USN to pass back.
    var pendingFullSync: Int32?
    /// Shown once, then cleared by the UI.
    var serverMessage: String?

    let paths: CollectionPaths
    private(set) var backend: AnkiBackend?

    /// Custom sync server for login; empty means AnkiWeb.
    var customEndpoint: String {
        get { UserDefaults.standard.string(forKey: "customSyncEndpoint") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "customSyncEndpoint") }
    }

    var isSyncing: Bool {
        if case .syncing = syncStatus { return true }
        return false
    }

    init() {
        do {
            paths = try CollectionPaths.defaultLocation()
        } catch {
            // Application Support is always available on iOS; fall back to tmp
            // only so the type is total.
            paths = CollectionPaths(folder: FileManager.default.temporaryDirectory.appendingPathComponent("Anki"))
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard backend == nil else { return }
        do {
            let backend = try AnkiBackend()
            try await backend.openCollection(at: paths)
            self.backend = backend
            credentials = CredentialStore.load()
            phase = .ready
            await refreshDecks()
            if credentials != nil {
                await sync()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func scenePhaseChanged(to scenePhase: ScenePhaseValue) {
        switch scenePhase {
        case .active:
            // Pull changes made on other devices, but don't hammer the server
            // when flipping between apps.
            if let lastSync, Date().timeIntervalSince(lastSync) < 5 * 60 { return }
            Task { await sync() }
        case .background:
            syncInBackground()
        case .inactive:
            break
        }
    }

    /// Push reviews when the user leaves the app. iOS gives us ~30s.
    private func syncInBackground() {
        guard credentials != nil, !isSyncing else { return }
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "AnkiSync") { [weak self] in
            Task { try? await self?.backend?.abortSync() }
        }
        Task {
            await sync(includeMedia: false)
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    func refreshDecks() async {
        guard let backend else { return }
        do {
            decks = try await backend.deckList()
        } catch {
            // Usually means a sync holds the collection; the list refreshes
            // when it finishes.
        }
    }

    // MARK: - Account

    func login(username: String, password: String) async throws {
        guard let backend else { return }
        let endpoint = customEndpoint.trimmingCharacters(in: .whitespaces)
        let creds = try await backend.login(
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            endpoint: endpoint.isEmpty ? nil : endpoint
        )
        try CredentialStore.save(creds)
        credentials = creds
        await sync()
    }

    func logout() {
        CredentialStore.delete()
        credentials = nil
        lastSync = nil
        syncStatus = .idle
    }

    // MARK: - Sync

    func sync(includeMedia: Bool = true) async {
        guard let backend, let credentials, !isSyncing else { return }
        syncStatus = .syncing(detail: nil)
        let poller = startProgressPolling(backend)
        defer { poller.cancel() }

        do {
            let report = try await backend.sync(credentials, syncMedia: includeMedia)
            if let endpoint = report.newEndpoint {
                var updated = credentials
                updated.endpoint = endpoint
                try? CredentialStore.save(updated)
                self.credentials = updated
            }
            serverMessage = report.serverMessage
            if case let .fullSyncRequired(usn) = report.outcome {
                pendingFullSync = usn
            } else {
                lastSync = Date()
            }
            syncStatus = .idle
            if includeMedia { watchMediaSync(backend) }
        } catch let error as AnkiError where error.isAuthFailure {
            logout()
            syncStatus = .failed("Please log in again.")
        } catch let error as AnkiError where error.isInterrupted {
            syncStatus = .idle
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
        await refreshDecks()
    }

    /// The user chose a side after `pendingFullSync` was set.
    func resolveFullSync(_ direction: FullSyncDirection) async {
        guard let backend, let credentials, let usn = pendingFullSync else { return }
        pendingFullSync = nil
        syncStatus = .syncing(detail: direction == .download ? "Downloading…" : "Uploading…")
        let poller = startProgressPolling(backend)
        defer { poller.cancel() }
        do {
            try await backend.fullSync(credentials, direction: direction, serverMediaUSN: usn)
            lastSync = Date()
            syncStatus = .idle
            watchMediaSync(backend)
        } catch let error as AnkiError where error.isInterrupted {
            syncStatus = .idle
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
        await refreshDecks()
    }

    func cancelSync() {
        Task { try? await backend?.abortSync() }
    }

    private func startProgressPolling(_ backend: AnkiBackend) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let progress = await backend.syncProgress() else { continue }
                guard let self, self.isSyncing else { return }
                self.syncStatus = .syncing(detail: Self.describe(progress))
            }
        }
    }

    private func watchMediaSync(_ backend: AnkiBackend) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                do {
                    let state = try await backend.mediaSyncState()
                    guard let self else { return }
                    if state.isActive {
                        self.mediaStatus = "Media: \(state.checked)"
                    } else {
                        self.mediaStatus = nil
                        return
                    }
                } catch {
                    self?.mediaStatus = "Media sync failed: \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    private static func describe(_ progress: SyncProgress) -> String {
        switch progress {
        case let .normal(stage, added, removed):
            [stage, added, removed].filter { !$0.isEmpty }.joined(separator: " · ")
        case let .full(transferred, total):
            total > 0
                ? "\(ByteCountFormatter.string(fromByteCount: Int64(transferred), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
                : "Transferring…"
        case let .media(checked, _, _):
            checked
        }
    }
}

/// Mirrors SwiftUI's ScenePhase so the model doesn't import SwiftUI.
enum ScenePhaseValue {
    case active, inactive, background
}
