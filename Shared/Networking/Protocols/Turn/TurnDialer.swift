//
//  TurnDialer.swift
//  Anywhere
//

import Foundation

/// Builds the `clientcore.Config` payload handed to the Go dialer.
///
/// Kept outside the `canImport(Turn)` guard so it can be exercised without the framework.
///
/// The Go core buckets sessions into credential caches by `streamID / streams_per_cred`,
/// and every cache authenticates against VK on its own — which means its own captcha.
/// With the subscription's `streams_per_cred` (2) against ten sessions that is five
/// separate captchas for one connect. Pinning `streams_per_cred` to at least the number
/// of sessions collapses that to a single cache (`cacheID` is always 0), so one solved
/// captcha warms the whole pool.
nonisolated enum TurnDialerConfig {

    /// Sessions the pool will actually run, after clamping. `peers` has usually already
    /// been trimmed by ``TurnMemory/effectivePeers(requested:)``; clamping again is what
    /// the Go side is handed, so the credential math has to be based on this value.
    static func sessionCount(peers: Int) -> Int {
        TurnLimits.clampPeers(peers)
    }

    /// Streams one credential set covers. Never below the session count, so the pool
    /// keeps exactly one credential cache regardless of what the subscription suggests.
    static func streamsPerCred(peers: Int, defaults: TurnDefaults?) -> Int {
        max(sessionCount(peers: peers), defaults?.streamsPerCred ?? 0)
    }

    /// Mirrors `clientcore.Config`. VLESS mode is forced on the Go side; the peer always
    /// forwards to its own configured backend, so no destination is carried here.
    ///
    /// - Parameter vkLink: already trimmed and validated by the caller.
    static func make(
        server: TurnServerInfo,
        vkLink: String,
        defaults: TurnDefaults?,
        peers: Int,
        manualCaptcha: Bool
    ) -> [String: Any] {
        var config: [String: Any] = [
            "peer_addr": server.peerAddr,
            "vk_link": vkLink,
            "vless_mode": true,
            "num_streams": sessionCount(peers: peers),
            "streams_per_cred": streamsPerCred(peers: peers, defaults: defaults),
            "manual_captcha": manualCaptcha,
        ]
        let wrapMode = defaults?.wrapMode ?? !server.wrapKeyHex.isEmpty
        if wrapMode {
            config["wrap_mode"] = true
            config["wrap_key_hex"] = server.wrapKeyHex
        }
        if let solver = defaults?.captchaSolver, !solver.isEmpty {
            config["captcha_solver"] = solver
        }
        return config
    }
}

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

    /// How far along the connection pipeline the Go pool is (`AnywherePhase*`).
    var phase: Int {
        closed.withLock { $0 } ? 0 : dialer.phase()
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

        let config = TurnDialerConfig.make(
            server: server,
            vkLink: link,
            defaults: defaults,
            peers: peers,
            manualCaptcha: manualCaptcha
        )
        let sessions = TurnDialerConfig.sessionCount(peers: peers)
        let streamsPerCred = TurnDialerConfig.streamsPerCred(peers: peers, defaults: defaults)

        let json = try JSONSerialization.data(withJSONObject: config)
        guard let configJSON = String(data: json, encoding: .utf8) else {
            throw TurnError.unsupportedServer(host: server.host)
        }

        var error: NSError?
        guard let dialer = AnywhereNewDialer(configJSON, TurnLogRelay(host: server.host), &error) else {
            throw error.map { TurnError.io($0) } ?? TurnError.unsupportedServer(host: server.host)
        }
        self.dialer = dialer
        // One line per dialer: the check that the pool runs a single credential cache
        // (streams_per_cred >= num_streams) and therefore asks for one captcha.
        logger.info("TURN dialer \(server.host): num_streams=\(sessions) streams_per_cred=\(streamsPerCred) (credential caches: \(sessions <= streamsPerCred ? 1 : (sessions + streamsPerCred - 1) / streamsPerCred))")
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
                    // WaitReady already hands pages back on the Go side; record where
                    // that left the extension's budget.
                    logger.debug("TURN ready: Go heap \(TurnMemory.goHeapBytes / (1 << 20)) MiB, \(TurnMemory.availableBytes / (1 << 20)) MiB available")
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
