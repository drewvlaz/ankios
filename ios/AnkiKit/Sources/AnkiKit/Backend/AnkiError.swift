import Foundation
import SwiftProtobuf

/// An error raised by the Rust backend (decoded `anki.backend.BackendError`).
public struct AnkiError: Error, LocalizedError, Sendable {
    public typealias Kind = Anki_Backend_BackendError.Kind

    public let kind: Kind
    /// Localized by rslib; suitable for showing to the user.
    public let message: String
    public let context: String

    init(backendErrorBytes bytes: Data) {
        if let decoded = try? Anki_Backend_BackendError(serializedBytes: bytes) {
            kind = decoded.kind
            message = decoded.message
            context = decoded.context
        } else {
            kind = .invalidInput
            message = "Undecodable backend error (\(bytes.count) bytes)"
            context = ""
        }
    }

    public var errorDescription: String? { message }

    /// The user (or `abortSync()`) cancelled the operation.
    public var isInterrupted: Bool { kind == .interrupted }
    /// Stored credentials are no longer valid; the user must log in again.
    public var isAuthFailure: Bool { kind == .syncAuthError }
    public var isNetworkFailure: Bool { kind == .networkError }
}

/// Failures in the Swift <-> Rust plumbing itself, as opposed to Anki errors.
public enum AnkiBridgeError: Error, LocalizedError {
    case initializationFailed(String)
    case malformedResponse(String, Error)

    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(message):
            "Couldn't start the Anki backend: \(message)"
        case let .malformedResponse(type, error):
            "Couldn't decode \(type) from the Anki backend: \(error.localizedDescription)"
        }
    }
}
