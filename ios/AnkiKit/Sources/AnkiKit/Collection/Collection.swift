import Foundation

/// On-disk layout of a collection, matching desktop Anki's conventions so the
/// folder can be inspected or copied with standard tools.
public struct CollectionPaths: Sendable, Equatable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var collection: URL { folder.appendingPathComponent("collection.anki2") }
    public var mediaFolder: URL { folder.appendingPathComponent("collection.media", isDirectory: true) }
    public var mediaDatabase: URL { folder.appendingPathComponent("collection.media.db2") }

    /// `Application Support/Anki/User 1`, created if missing.
    public static func defaultLocation() throws -> CollectionPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return CollectionPaths(folder: support.appendingPathComponent("Anki/User 1", isDirectory: true))
    }
}

extension AnkiBackend {
    /// Open (creating if needed) the collection at `paths`.
    public func openCollection(at paths: CollectionPaths) async throws {
        try FileManager.default.createDirectory(at: paths.mediaFolder, withIntermediateDirectories: true)
        var request = Anki_Collection_OpenCollectionRequest()
        request.collectionPath = paths.collection.path
        request.mediaFolderPath = paths.mediaFolder.path
        request.mediaDbPath = paths.mediaDatabase.path
        try await openCollection(request)
    }

    public func closeCollection() async throws {
        try await closeCollection(Anki_Collection_CloseCollectionRequest())
    }
}
