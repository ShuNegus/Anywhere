//
//  TurnDialer.swift
//  Anywhere
//

import Foundation

#if canImport(Turn)
import Turn
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnDialer")

/// Swift face of the Go `clientcore.Dialer`: a pool of TURN sessions to one relay that
/// hands out streams on demand.
///
/// Construction is cheap — the Go side starts maintaining sessions in the background and
/// returns at once — so the pool only really exists after `waitReady()` succeeds.
nonisolated final class TurnDialer: Sendable {

    let host: String

    nonisolated(unsafe) private let dialer: AnywhereDialer
    private let readyTimeout: TimeInterval
    private let streamCounter = Atomic<Int>(0)
    private let closed = Mutex(false)

    /// Sessions currently held open to the relay.
    var sessionCount: Int {
        closed.withLock { $0 } ? 0 : dialer.sessionCount()
    }

    /// Streams handed out and not yet closed.
    var openStreamCount: Int {
        streamCounter.load(ordering: .relaxed)
    }

    init(server: TurnServerInfo, vkLink: String, defaults: TurnDefaults?, peers: Int, manualCaptcha: Bool) throws {
        guard server.isUsable else { throw TurnError.unsupportedServer(host: server.host) }
        let link = vkLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { throw TurnError.missingVKLink }

        self.host = server.host
        self.readyTimeout = TimeInterval(defaults?.readyTimeout ?? 30)

        // Mirrors clientcore.Config. VLESS mode is forced on the Go side; the peer always
        // forwards to its own configured backend, so no destination is carried here.
        var config: [String: Any] = [
            "peer_addr": server.peerAddr,
            "vk_link": link,
            "vless_mode": true,
            "num_streams": TurnLimits.clampPeers(peers),
            "manual_captcha": manualCaptcha,
        ]
        let wrapMode = defaults?.wrapMode ?? !server.wrapKeyHex.isEmpty
        if wrapMode {
            config["wrap_mode"] = true
            config["wrap_key_hex"] = server.wrapKeyHex
        }
        if let streamsPerCred = defaults?.streamsPerCred, streamsPerCred > 0 {
            config["streams_per_cred"] = streamsPerCred
        }
        if let solver = defaults?.captchaSolver, !solver.isEmpty {
            config["captcha_solver"] = solver
        }

        let json = try JSONSerialization.data(withJSONObject: config)
        guard let configJSON = String(data: json, encoding: .utf8) else {
            throw TurnError.unsupportedServer(host: server.host)
        }

        var error: NSError?
        guard let dialer = AnywhereNewDialer(configJSON, TurnLogRelay(host: server.host), &error) else {
            throw error.map { TurnError.io($0) } ?? TurnError.unsupportedServer(host: server.host)
        }
        self.dialer = dialer
        logger.debug("TURN dialer created for \(server.host) via \(server.peerAddr), peers=\(TurnLimits.clampPeers(peers))")
    }

    /// Blocks until at least one session is up. Cheap to call repeatedly — it returns
    /// immediately once the pool is warm.
    func waitReady(timeout: TimeInterval? = nil) async throws {
        if closed.withLock({ $0 }) { throw TurnError.streamClosed }
        let milliseconds = Int(max(1, (timeout ?? readyTimeout) * 1000))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Blocking Go call; keep it off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async { [dialer] in
                do {
                    try dialer.waitReady(milliseconds)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: TurnError.notReady)
                }
            }
        }
    }

    /// Opens a fresh multiplexed stream over an established session.
    func openStream() throws -> TurnStream {
        if closed.withLock({ $0 }) { throw TurnError.streamClosed }
        let raw: AnywhereStream
        do {
            raw = try dialer.dial()
        } catch {
            throw TurnError.io(error)
        }
        let index = streamCounter.wrappingAdd(1, ordering: .relaxed).newValue
        return TurnStream(stream: raw, label: "\(host)-\(index)")
    }

    /// Balances `openStream()`; used only for the live stream count.
    func noteStreamClosed() {
        streamCounter.wrappingSubtract(1, ordering: .relaxed)
    }

    func close() {
        let wasOpen = closed.withLock { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        DispatchQueue.global(qos: .utility).async { [dialer, host] in
            try? dialer.close()
            logger.debug("TURN dialer closed for \(host)")
        }
    }
}

// MARK: - Log relay

/// Forwards the Go core's log lines into the app's logger. `[VK Auth]` and `[session N]`
/// lines from here are the main signal that the relay handshake is progressing.
nonisolated private final class TurnLogRelay: NSObject, AnywhereLogSinkProtocol {
    private let host: String

    init(host: String) {
        self.host = host
        super.init()
    }

    func onLog(_ msg: String?) {
        guard let msg, !msg.isEmpty else { return }
        logger.debug("[turn \(host)] \(msg)")
    }
}
#endif
