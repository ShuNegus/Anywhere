//
//  TurnProxyConnection.swift
//  Anywhere
//

import Foundation

#if canImport(Turn)
import Synchronization

/// A `ProxyConnection` backed by one TURN stream.
///
/// It is never the outbound protocol itself — it is handed to `ProxyClient` as its
/// `tunnel`, so the whole proxy stack (TLS/Reality/WS/HTTPUpgrade/gRPC/XHTTP) is built
/// on top of it. That is the direct analogue of a sing-box `detour`.
nonisolated final class TurnProxyConnection: ProxyConnection {

    private let stream: TurnStream
    private let onClose: @Sendable () -> Void
    private let cancelled = Mutex(false)

    var outerTLSVersion: TLSVersion? { nil }

    /// TURN carries a byte stream; UDP is not tunnelled through it.
    var deliversDatagrams: Bool { false }

    var isConnected: Bool {
        !cancelled.withLock { $0 } && stream.isOpen
    }

    init(stream: TurnStream, onClose: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.onClose = onClose
    }

    deinit {
        if !cancelled.withLock({ $0 }) {
            stream.close()
            onClose()
        }
    }

    func sendRaw(_ data: Data) async throws {
        guard isConnected else { throw TurnError.streamClosed }
        try await stream.write(data)
    }

    func receiveRaw() async throws -> Data? {
        guard isConnected else { return nil }
        return try await stream.read()
    }

    func cancel() {
        let wasLive = cancelled.withLock { cancelled -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        guard wasLive else { return }
        stream.close()
        onClose()
    }
}
#endif
