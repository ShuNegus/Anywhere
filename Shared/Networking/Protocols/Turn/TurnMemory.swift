//
//  TurnMemory.swift
//  Anywhere
//

import Foundation
import os

#if canImport(Turn)
import Turn

nonisolated private let logger = AnywhereLogger(category: "TurnMemory")

/// Keeps the Go runtime inside the Network Extension's memory budget.
///
/// A packet-tunnel extension gets on the order of 50 MB for the whole process — the lwIP
/// stack, every proxy connection, and the TURN core together. The Go heap is the one
/// tenant that will happily grow to fill whatever it is given, so it is handed an explicit
/// soft limit derived from what iOS says is actually left, and the session count is capped
/// when headroom is thin.
nonisolated enum TurnMemory {

    /// Fraction of the remaining budget the Go runtime may use as its soft limit.
    private static let goHeapShare = 0.4
    /// Never hand Go a limit below this — under it the handshake cannot complete at all.
    private static let minimumGoLimit: Int64 = 12 << 20
    /// Below this much headroom, run a reduced number of sessions.
    private static let lowMemoryThreshold: Int64 = 20 << 20
    /// Session cap applied under memory pressure.
    private static let lowMemoryPeerCap = 4

    /// Bytes this process may still allocate before iOS kills it.
    static var availableBytes: Int64 {
        Int64(os_proc_available_memory())
    }

    /// Applies a soft heap limit proportional to the remaining budget.
    /// Called once per dialer creation, which is also when the budget last changed.
    static func applyBudget() {
        let available = availableBytes
        guard available > 0 else {
            // os_proc_available_memory returns 0 outside an app extension; leave the
            // Go defaults in place there.
            return
        }
        let limit = max(minimumGoLimit, Int64(Double(available) * goHeapShare))
        AnywhereConfigureMemory(limit, 0)
        logger.debug("TURN memory budget: \(available / (1 << 20)) MiB available, Go soft limit \(limit / (1 << 20)) MiB")
    }

    /// The session count to actually use, given the peers the user asked for and the
    /// headroom left. Each session carries its own DTLS/KCP state, so this is the most
    /// effective lever when memory is tight.
    static func effectivePeers(requested: Int) -> Int {
        let available = availableBytes
        guard available > 0, available < lowMemoryThreshold else {
            return TurnLimits.clampPeers(requested)
        }
        let capped = min(TurnLimits.clampPeers(requested), lowMemoryPeerCap)
        logger.debug("TURN low memory (\(available / (1 << 20)) MiB): capping peers \(requested) → \(capped)")
        return capped
    }

    /// Returns freed pages to the OS. Worth calling after the handshake, which is by far
    /// the most allocation-heavy phase.
    static func release() {
        AnywhereFreeMemory()
    }

    /// Live Go heap size, for logging.
    static var goHeapBytes: Int64 {
        AnywhereHeapInUse()
    }
}
#endif
