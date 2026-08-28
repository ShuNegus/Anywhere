//
//  TurnDialerRegistry.swift
//  Anywhere
//

import Foundation

#if canImport(Turn)
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnDialerRegistry")

/// One `TurnDialer` per relay host, shared by every flow that goes through that host.
///
/// Dialers are expensive (a pool of TURN sessions, a VK handshake, possibly a captcha)
/// and cheap to reuse, so they are created lazily on first use and live as long as the
/// tunnel session does. `reset()` tears them all down — call it when the tunnel stops or
/// its configuration changes, so a new session never inherits a stale pool.
nonisolated final class TurnDialerRegistry: Sendable {

    static let shared = TurnDialerRegistry()

    private struct State {
        var dialers: [String: TurnDialer] = [:]
        /// The settings the live dialers were built from; a change invalidates them.
        var fingerprint: String = ""
    }

    private let state = Mutex(State())

    private init() {}

    /// Whether TURN should be used at all right now. In `.auto` this follows the
    /// autopilot's verdict, so flows go direct until a probe says the network is censored.
    static var isActive: Bool {
        guard AWCore.getTurnFeatureEnabled(), !effectiveVKLink().isEmpty else { return false }
        switch AWCore.getTurnMode() {
        case .off: return false
        case .on: return true
        case .auto: return TurnAutoState.shared.decision == .turn
        }
    }

    /// The VK Calls link to dial with: the user's own entry wins, otherwise the one the
    /// subscription shipped.
    static func effectiveVKLink() -> String {
        let manual = AWCore.getTurnVKLink().trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return TurnMetadataStore.shared.subscriptionVKLink()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Returns the dialer for `host`, creating it on first use. `nil` when TURN is off,
    /// unconfigured, or the subscription lists no usable relay for that host.
    func dialer(for host: String) -> TurnDialer? {
        guard Self.isActive else { return nil }
        guard let server = TurnMetadataStore.shared.server(for: host), server.isUsable else { return nil }

        let vkLink = Self.effectiveVKLink()
        let requestedPeers = AWCore.getTurnPeers()
        let manualCaptcha = AWCore.getTurnCaptchaManual()
        // Only what the *user* configured goes in here. The memory-derived session cap
        // must not: it moves with the traffic the pools are carrying, and a pool that
        // rebuilt mid-transfer would drop every live stream on the floor.
        let fingerprint = TurnPoolFingerprint.make(
            vkLink: vkLink,
            peers: requestedPeers,
            manualCaptcha: manualCaptcha
        )

        // Drop everything if the settings behind the live pools have changed.
        let stale: [TurnDialer] = state.withLock { state in
            guard state.fingerprint != fingerprint, !state.dialers.isEmpty else {
                state.fingerprint = fingerprint
                return []
            }
            let old = Array(state.dialers.values)
            state.dialers.removeAll()
            state.fingerprint = fingerprint
            return old
        }
        if !stale.isEmpty {
            logger.info("TURN settings changed: closing \(stale.count) live dialer(s), pools will be rebuilt")
            stale.forEach { $0.close() }
        }

        if let existing = state.withLock({ $0.dialers[server.host] }) { return existing }

        TurnMemory.applyBudget()
        // Trimmed to what the extension's remaining budget can carry — applied to this
        // new pool only, never to pools that are already running.
        let peers = TurnMemory.effectivePeers(requested: requestedPeers)

        let dialer: TurnDialer
        do {
            dialer = try TurnDialer(
                server: server,
                vkLink: vkLink,
                defaults: TurnMetadataStore.shared.defaults(for: server.host),
                peers: peers,
                manualCaptcha: manualCaptcha
            )
        } catch {
            logger.debug("TURN dialer unavailable for \(host): \(error.localizedDescription)")
            return nil
        }

        // Another flow may have raced us here; keep whichever landed first.
        let winner = state.withLock { state -> TurnDialer in
            if let existing = state.dialers[server.host] { return existing }
            state.dialers[server.host] = dialer
            return dialer
        }
        if winner !== dialer { dialer.close() }
        return winner
    }

    /// Opens a TURN-backed tunnel to `host`, or returns `nil` to fall back to a direct dial.
    func tunnel(for host: String) async -> ProxyConnection? {
        guard let dialer = dialer(for: host) else { return nil }
        do {
            try await dialer.waitReady()
            let stream: TurnStream
            do {
                stream = try dialer.openStream()
            } catch {
                // One session of the pool may be mid-reconnect; the Go side round-robins,
                // so a single retry usually lands on a healthy one.
                logger.debug("TURN stream to \(host) failed (\(error.localizedDescription)), retrying once")
                stream = try dialer.openStream()
            }
            return TurnProxyConnection(stream: stream) { [weak dialer] in
                dialer?.noteStreamClosed()
            }
        } catch {
            // Worth an info line: TURN is on because the direct path is expected to be
            // blocked, so a silent fallback is a flow that dies for no visible reason.
            logger.info("TURN tunnel to \(host) unavailable (\(error.localizedDescription)); falling back to a direct dial")
            return nil
        }
    }

    /// Live counts for the settings screen, keyed by relay host.
    func statistics() -> [TurnHostStatistics] {
        state.withLock { $0.dialers }
            .values
            .map { TurnHostStatistics(host: $0.host, sessions: $0.sessionCount, streams: $0.openStreamCount, phase: $0.phase) }
            .sorted { $0.host < $1.host }
    }

    /// Tears down every pool. Call on tunnel stop or reconfiguration.
    func reset() {
        let dialers: [TurnDialer] = state.withLock { state in
            let all = Array(state.dialers.values)
            state.dialers.removeAll()
            state.fingerprint = ""
            return all
        }
        guard !dialers.isEmpty else { return }
        logger.info("TURN reset: closing \(dialers.count) dialer(s) (tunnel stop or reconfiguration)")
        dialers.forEach { $0.close() }
    }
}
#endif

/// The identity of a live TURN pool: change any of these and the pools have to be rebuilt.
///
/// Declared unconditionally, and free of any global state, so the invariant that runtime
/// conditions (memory headroom in particular) never enter it can be tested without
/// linking `Turn.xcframework`.
nonisolated enum TurnPoolFingerprint {
    /// - Parameter peers: the *user's* setting, not the memory-adjusted session count.
    static func make(vkLink: String, peers: Int, manualCaptcha: Bool) -> String {
        "\(vkLink)|\(peers)|\(manualCaptcha)"
    }
}

/// Per-relay live counts. Declared unconditionally so the UI can display it in targets
/// that do not link `Turn.xcframework`.
nonisolated struct TurnHostStatistics: Codable, Hashable, Sendable, Identifiable {
    let host: String
    let sessions: Int
    let streams: Int
    /// Raw `AnywherePhase*` value. Optional so that decoding stays tolerant across
    /// an extension/app version skew in either direction.
    let phase: Int?

    var id: String { host }
}
