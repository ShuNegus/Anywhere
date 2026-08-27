//
//  TurnError.swift
//  Anywhere
//

import Foundation

/// Errors from the TURN transport. Defined unconditionally so code outside the Network
/// Extension — where `Turn.xcframework` is not linked — can still name them.
nonisolated enum TurnError: LocalizedError {
    /// `Turn.xcframework` is not linked into this target.
    case unavailable
    /// No VK Calls link has been configured, so the relay cannot authenticate.
    case missingVKLink
    /// The subscription lists no usable relay for this proxy host.
    case unsupportedServer(host: String)
    /// No TURN session came up before the deadline.
    case notReady
    case streamClosed
    case io(any Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "The TURN transport is not available in this build.")
        case .missingVKLink:
            String(localized: "No VK Calls link is configured for TURN.")
        case .unsupportedServer(let host):
            String(localized: "No TURN relay is available for \(host).")
        case .notReady:
            String(localized: "No TURN session could be established.")
        case .streamClosed:
            String(localized: "The TURN stream is closed.")
        case .io(let underlying):
            underlying.localizedDescription
        }
    }

    /// Whether a Go-side error is really an orderly end of stream.
    static func isEndOfStream(_ error: any Error) -> Bool {
        let message = (error as NSError).localizedDescription
        return message == "EOF" || message.hasSuffix("EOF")
    }
}
