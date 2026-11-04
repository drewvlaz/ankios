import AnkiBridgeFFI
import Foundation
import SwiftProtobuf

/// Thin, thread-safe handle to Anki's Rust backend.
///
/// Every RPC is `protobuf in -> protobuf out`. The typed methods
/// (`deckTree(_:)`, `syncCollection(_:)`, ...) live in the generated
/// `AnkiBackend+Services.swift`; they all funnel through `run(service:method:input:as:)`.
///
/// Calls block inside Rust (a sync can take minutes), so they're dispatched onto
/// a concurrent queue and never touch the caller's thread. rslib serialises
/// collection access with its own mutex, which means a long sync will make other
/// collection calls wait; backend-only calls such as `latestProgress()` and
/// `abortSync()` don't take that lock and can run alongside it.
public final class AnkiBackend: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(
        label: "anki.backend",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init(preferredLanguages: [String] = Locale.preferredLanguages) throws {
        var initMsg = Anki_Backend_BackendInit()
        initMsg.preferredLangs = preferredLanguages
        let bytes: Data = try initMsg.serializedBytes()

        var error = AnkiBuffer(data: nil, len: 0)
        let handle = bytes.withUnsafeBytes { raw in
            anki_backend_new(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &error)
        }
        guard let handle else {
            let message = String(decoding: Self.take(error), as: UTF8.self)
            throw AnkiBridgeError.initializationFailed(message)
        }
        self.handle = handle
    }

    deinit {
        anki_backend_free(handle)
    }

    /// rslib's build hash, for an About screen.
    public static var buildHash: String {
        String(decoding: take(anki_buildhash()), as: UTF8.self)
    }

    /// Route rslib's logs to a file. Call once, before creating a backend.
    @discardableResult
    public static func enableLogging(to url: URL) -> Bool {
        url.path.withCString { anki_init_logging($0) }
    }

    // MARK: - RPC plumbing

    public func run<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        service: UInt32,
        method: UInt32,
        input: Input,
        as _: Output.Type
    ) async throws -> Output {
        let bytes: Data = try input.serializedBytes()
        let (ok, output) = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.runBlocking(service: service, method: method, input: bytes))
            }
        }
        guard ok else {
            throw AnkiError(backendErrorBytes: output)
        }
        do {
            return try Output(serializedBytes: output)
        } catch {
            throw AnkiBridgeError.malformedResponse(String(describing: Output.self), error)
        }
    }

    private func runBlocking(service: UInt32, method: UInt32, input: Data) -> (Bool, Data) {
        var out = AnkiBuffer(data: nil, len: 0)
        let ok = input.withUnsafeBytes { raw in
            anki_backend_run(
                handle,
                service,
                method,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                &out
            )
        }
        return (ok, Self.take(out))
    }

    /// Copy a Rust-owned buffer into `Data` and release it.
    private static func take(_ buffer: AnkiBuffer) -> Data {
        defer { anki_buffer_free(buffer) }
        guard let data = buffer.data, buffer.len > 0 else { return Data() }
        return Data(bytes: data, count: buffer.len)
    }
}
