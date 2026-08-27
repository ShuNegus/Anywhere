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

    /// Whether TURN should be used at all right now.
    static var isActive: Bool {
        AWCore.getTurnFeatureEnabled()
            && AWCore.getTurnEnabled()
            && !effectiveVKLink().isEmpty
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
        // Trimmed to what the extension's remaining memory budget can actually carry.
        let peers = TurnMemory.effectivePeers(requested: AWCore.getTurnPeers())
        let manualCaptcha = AWCore.getTurnCaptchaManual()
        let fingerprint = "\(vkLink)|\(peers)|\(manualCaptcha)"

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
        stale.forEach { $0.close() }

        if let existing = state.withLock({ $0.dialers[server.host] }) { return existing }

        TurnMemory.applyBudget()

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
            let stream = try dialer.openStream()
            return TurnProxyConnection(stream: stream) { [weak dialer] in
                dialer?.noteStreamClosed()
            }
        } catch {
            logger.debug("TURN tunnel to \(host) unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Live counts for the settings screen, keyed by relay host.
    func statistics() -> [TurnHostStatistics] {
        state.withLock { $0.dialers }
            .values
            .map { TurnHostStatistics(host: $0.host, sessions: $0.sessionCount, streams: $0.openStreamCount) }
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
        logger.debug("resetting \(dialers.count) TURN dialer(s)")
        dialers.forEach { $0.close() }
    }
}
#endif

/// Per-relay live counts. Declared unconditionally so the UI can display it in targets
/// that do not link `Turn.xcframework`.
nonisolated struct TurnHostStatistics: Codable, Hashable, Sendable, Identifiable {
    let host: String
    let sessions: Int
    let streams: Int

    var id: String { host }
}
