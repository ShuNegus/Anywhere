//
//  RealityRejectionGate.swift
//  Anywhere
//
//  Circuit breaker for REALITY servers that reject our ClientHello.
//
//  A REALITY server that does not accept the client (Xray ≥ 26.9.9 without an
//  X25519MLKEM768 key share, a rotated key, a wrong shortId…) sends no error: it
//  splices the connection to the donor site, and we only notice when the donor's
//  genuine certificate fails our check (`.reality(.authenticationFailed)`). Every app
//  flow would otherwise open its own doomed connection — through TURN that piled up
//  hundreds of stuck streams on one node. After a rejection the server is blocked for
//  2, 4, 8, 16, 32, then 60 s; a successful handshake resets it.
//
//  Latency probes bypass the gate (`RealityRejectionGate.$bypass`) so the user can
//  always re-test a server by hand; their outcome still updates the state.
//

import Foundation
import Synchronization

nonisolated final class RealityRejectionGate: Sendable {

    /// Server identity: endpoint (`host:port` as configured, never a resolved IP, so
    /// the direct and the over-tunnel path agree) plus the REALITY parameters.
    struct Key: Hashable, Sendable {
        let endpoint: String
        let serverName: String
        let publicKey: Data
        let shortId: Data

        init(endpoint: String, serverName: String, publicKey: Data, shortId: Data) {
            self.endpoint = endpoint
            self.serverName = serverName
            self.publicKey = publicKey
            self.shortId = shortId
        }

        init(endpoint: String, reality: RealityConfiguration) {
            self.init(
                endpoint: endpoint,
                serverName: reality.serverName,
                publicKey: reality.publicKey,
                shortId: reality.shortId
            )
        }

        /// Stable text form shared with the app through the app group.
        var identity: String {
            "\(endpoint)|\(serverName)|\(publicKey.base64URLEncodedString())|\(shortId.hexEncodedString())"
        }
    }

    private struct Entry {
        var failures: Int
        var blockedUntil: TimeInterval
    }

    static let shared = RealityRejectionGate()

    /// Set by the latency tester: probes neither wait for nor are refused by the gate.
    @TaskLocal static var bypass = false

    static let maxBlock: TimeInterval = 60

    /// 2 · 2^(n-1) seconds, capped at 60: 2, 4, 8, 16, 32, 60, 60…
    static func blockDuration(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 6)
        return min(maxBlock, 2 * Double(1 << exponent))
    }

    private let now: @Sendable () -> TimeInterval
    private let entries = Mutex<[Key: Entry]>([:])

    init(now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now }) {
        self.now = now
    }

    /// Seconds left on the block for `key`, or `nil` when connecting is allowed.
    func remainingBlock(for key: Key) -> TimeInterval? {
        let current = now()
        return entries.withLock { entries -> TimeInterval? in
            guard let entry = entries[key], entry.blockedUntil > current else { return nil }
            return entry.blockedUntil - current
        }
    }

    /// The error to fail with instead of dialing, or `nil` to go ahead.
    func refusal(for key: Key) -> AnywhereError? {
        guard !Self.bypass, remainingBlock(for: key) != nil else { return nil }
        return AnywhereError.tls(.reality(.rejectedRecently))
    }

    /// Records a rejection. Rejections that land while the key is already blocked come
    /// from attempts that started before the block and do not lengthen it — otherwise a
    /// burst of parallel flows would jump straight to the 60 s cap.
    /// - Returns: `true` when this opened a new block window.
    @discardableResult
    func recordRejection(for key: Key) -> Bool {
        let current = now()
        return entries.withLock { entries -> Bool in
            var entry = entries[key] ?? Entry(failures: 0, blockedUntil: 0)
            guard entry.blockedUntil <= current else { return false }
            entry.failures += 1
            entry.blockedUntil = current + Self.blockDuration(afterFailures: entry.failures)
            entries[key] = entry
            return true
        }
    }

    /// Records a successful handshake and lifts any block.
    /// - Returns: `true` when the key had been rejected before.
    @discardableResult
    func recordSuccess(for key: Key) -> Bool {
        entries.withLock { $0.removeValue(forKey: key) != nil }
    }

    func reset() {
        entries.withLock { $0.removeAll() }
    }
}

// MARK: - Configuration helpers

nonisolated extension ProxyConfiguration {
    /// Gate key for this configuration's own REALITY layer, `nil` when it has none.
    var realityRejectionKey: RealityRejectionGate.Key? {
        guard case .reality(let reality) = xraySecurityLayer else { return nil }
        return RealityRejectionGate.Key(endpoint: "\(serverAddress):\(serverPort)", reality: reality)
    }

    /// Keys of this configuration and every hop of its chain.
    var realityRejectionKeys: [RealityRejectionGate.Key] {
        ([self] + (chain ?? [])).compactMap(\.realityRejectionKey)
    }
}

// MARK: - App group hint

/// The extension remembers the last rejection so the home screen can tell the user
/// why nothing loads ("update the app") instead of leaving them with a timeout.
nonisolated enum RealityRejectionNotice {
    /// How long a recorded rejection stays relevant for the home screen hint.
    static let freshness: TimeInterval = 90

    static func noteRejected(_ key: RealityRejectionGate.Key) {
        AWCore.setRealityRejection(identity: key.identity, at: Date().timeIntervalSince1970)
    }

    static func noteAccepted(_ key: RealityRejectionGate.Key) {
        guard AWCore.getRealityRejection()?.identity == key.identity else { return }
        AWCore.setRealityRejection(identity: nil, at: 0)
    }

    /// Whether one of `keys` was rejected within ``freshness`` seconds (a 60 s block plus slack) of `now`.
    static func isRecentlyRejected(
        _ keys: [RealityRejectionGate.Key],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let record = AWCore.getRealityRejection() else { return false }
        return isFresh(record: record, keys: keys, now: now)
    }

    static func isFresh(
        record: (identity: String, at: TimeInterval),
        keys: [RealityRejectionGate.Key],
        now: TimeInterval
    ) -> Bool {
        let age = now - record.at
        guard age >= 0, age <= freshness else { return false }
        return keys.contains { $0.identity == record.identity }
    }
}

nonisolated extension AnywhereError {
    /// The server rejected us, now or moments ago.
    var isRealityRejection: Bool {
        switch self {
        case .tls(.reality(.authenticationFailed)), .tls(.reality(.rejectedRecently)): true
        default: false
        }
    }
}
