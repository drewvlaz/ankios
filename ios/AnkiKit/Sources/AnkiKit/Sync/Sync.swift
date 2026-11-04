import Foundation

/// What the app persists after login. `hostKey` is a long-lived token; the
/// password is never stored.
public struct SyncCredentials: Codable, Equatable, Sendable {
    public var username: String
    public var hostKey: String
    /// Sync server base URL. nil means AnkiWeb. AnkiWeb may also hand back a
    /// specific shard via `SyncReport.newEndpoint`, which must be persisted.
    public var endpoint: String?

    public init(username: String, hostKey: String, endpoint: String?) {
        self.username = username
        self.hostKey = hostKey
        self.endpoint = endpoint
    }

    var auth: Anki_Sync_SyncAuth {
        var auth = Anki_Sync_SyncAuth()
        auth.hkey = hostKey
        if let endpoint { auth.endpoint = endpoint }
        return auth
    }
}

public enum FullSyncDirection: Sendable {
    /// Replace this device's collection with the server's copy.
    case download
    /// Replace the server's collection with this device's copy.
    case upload
}

public enum SyncOutcome: Sendable, Equatable {
    /// Collection is in sync (normal sync done, or nothing to do).
    case synced
    /// A one-way full sync ran automatically because one side was empty.
    case fullSyncCompleted(FullSyncDirection)
    /// Both sides have diverged (e.g. a schema change). The user must choose a
    /// direction; call `fullSync(_:direction:serverMediaUSN:)` with it.
    case fullSyncRequired(serverMediaUSN: Int32)
}

public struct SyncReport: Sendable, Equatable {
    public var outcome: SyncOutcome
    /// Non-empty when the server wants to show the user something.
    public var serverMessage: String?
    /// If set, update and persist `SyncCredentials.endpoint`.
    public var newEndpoint: String?
}

public enum SyncProgress: Sendable, Equatable {
    case normal(stage: String, added: String, removed: String)
    case full(transferredBytes: UInt32, totalBytes: UInt32)
    case media(checked: String, added: String, removed: String)
}

public struct MediaSyncState: Sendable, Equatable {
    public var isActive: Bool
    public var checked: String
    public var added: String
    public var removed: String
}

extension AnkiBackend {
    /// Log in with username/password. Pass `endpoint` for a self-hosted server
    /// (e.g. "http://192.168.1.10:8080/"); nil means AnkiWeb.
    public func login(username: String, password: String, endpoint: String?) async throws -> SyncCredentials {
        var request = Anki_Sync_SyncLoginRequest()
        request.username = username
        request.password = password
        if let endpoint { request.endpoint = endpoint }
        let auth = try await syncLogin(request)
        // The server may not echo the endpoint back; keep what we used.
        return SyncCredentials(
            username: username,
            hostKey: auth.hkey,
            endpoint: auth.hasEndpoint ? auth.endpoint : endpoint
        )
    }

    /// Sync the collection, then (unless a full sync is pending) kick off a
    /// media sync in the background. Poll `mediaSyncState()` to follow it.
    ///
    /// If one side is empty the required one-way full sync runs automatically:
    /// that's what pulls your decks down on first login. If both sides have
    /// changes that can't be merged, returns `.fullSyncRequired` and does nothing
    /// destructive.
    public func sync(_ credentials: SyncCredentials, syncMedia: Bool = true) async throws -> SyncReport {
        var request = Anki_Sync_SyncCollectionRequest()
        request.auth = credentials.auth
        request.syncMedia = syncMedia
        let response = try await syncCollection(request)

        var effective = credentials
        let newEndpoint = response.hasNewEndpoint ? response.newEndpoint : nil
        if let newEndpoint { effective.endpoint = newEndpoint }

        let outcome: SyncOutcome
        switch response.required {
        case .noChanges, .normalSync:
            outcome = .synced
        case .fullDownload:
            try await fullSync(effective, direction: .download, serverMediaUSN: syncMedia ? response.serverMediaUsn : nil)
            outcome = .fullSyncCompleted(.download)
        case .fullUpload:
            try await fullSync(effective, direction: .upload, serverMediaUSN: syncMedia ? response.serverMediaUsn : nil)
            outcome = .fullSyncCompleted(.upload)
        case .fullSync:
            outcome = .fullSyncRequired(serverMediaUSN: response.serverMediaUsn)
        case .UNRECOGNIZED:
            outcome = .fullSyncRequired(serverMediaUSN: response.serverMediaUsn)
        }

        return SyncReport(
            outcome: outcome,
            serverMessage: response.serverMessage.isEmpty ? nil : response.serverMessage,
            newEndpoint: newEndpoint
        )
    }

    /// One-way full sync. The backend closes and reopens the collection around
    /// it. Pass `serverMediaUSN` to follow up with a media sync.
    public func fullSync(_ credentials: SyncCredentials, direction: FullSyncDirection, serverMediaUSN: Int32?) async throws {
        var request = Anki_Sync_FullUploadOrDownloadRequest()
        request.auth = credentials.auth
        request.upload = direction == .upload
        if let serverMediaUSN { request.serverUsn = serverMediaUSN }
        try await fullUploadOrDownload(request)
    }

    /// Current progress of whatever long-running operation is active.
    public func syncProgress() async -> SyncProgress? {
        guard let progress = try? await latestProgress() else { return nil }
        switch progress.value {
        case let .normalSync(p)?:
            return .normal(stage: p.stage, added: p.added, removed: p.removed)
        case let .fullSync(p)?:
            return .full(transferredBytes: p.transferred, totalBytes: p.total)
        case let .mediaSync(p)?:
            return .media(checked: p.checked, added: p.added, removed: p.removed)
        default:
            return nil
        }
    }

    /// Throws if the last media sync failed (the error is reported once).
    public func mediaSyncState() async throws -> MediaSyncState {
        let status = try await mediaSyncStatus()
        return MediaSyncState(
            isActive: status.active,
            checked: status.progress.checked,
            added: status.progress.added,
            removed: status.progress.removed
        )
    }
}
