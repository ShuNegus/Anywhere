//
//  TurnMemory.swift
//  Anywhere
//

import Foundation
import Synchronization
import os

/// The numbers behind the Go runtime's memory budget and the session cap.
///
/// Kept outside the `canImport(Turn)` guard, and free of any global state, so the policy
/// can be exercised in tests that do not link `Turn.xcframework`.
nonisolated enum TurnMemoryPolicy {

    /// Fraction of the remaining budget the Go runtime may use as its soft limit.
    static let goHeapShare = 0.6
    /// Never hand Go a limit below this — under it the handshake cannot complete at all.
    static let minimumGoLimit: Int64 = 16 << 20
    /// Never hand Go more than this: a packet-tunnel extension gets ~50 MB for the whole
    /// process, and being jetsam-killed is worse than a slower GC.
    static let maximumGoLimit: Int64 = 28 << 20
    /// GC target percentage handed to the Go runtime. Higher than Go's own default trade
    /// of 100 would be, but well above the 20 that used to make the collector run several
    /// times a second under load and stall the KCP/smux goroutines with GC assists.
    static let goGCPercent = 50

    /// Below this much headroom, start running a reduced number of sessions.
    static let lowMemoryThreshold: Int64 = 20 << 20
    /// The cap is only lifted once headroom recovers past this — the gap keeps a pool
    /// from flapping between cap states while memory hovers around the threshold.
    static let capReleaseThreshold: Int64 = 28 << 20
    /// Session cap applied under memory pressure.
    static let lowMemoryPeerCap = 4

    /// Soft heap limit for the Go runtime, given the bytes this process may still allocate.
    static func goLimit(available: Int64) -> Int64 {
        min(maximumGoLimit, max(minimumGoLimit, Int64(Double(available) * goHeapShare)))
    }

    /// Sessions a *newly created* pool should run, plus the cap state to carry forward.
    ///
    /// - Parameters:
    ///   - requested: what the user asked for.
    ///   - available: remaining process budget, or 0 when unknown (outside an extension).
    ///   - capActive: whether the cap was already engaged.
    static func peers(requested: Int, available: Int64, capActive: Bool) -> (peers: Int, capActive: Bool) {
        let clamped = TurnLimits.clampPeers(requested)
        guard available > 0 else { return (clamped, capActive) }
        let engaged: Bool
        if capActive {
            engaged = available <= capReleaseThreshold
        } else {
            engaged = available < lowMemoryThreshold
        }
        return (engaged ? min(clamped, lowMemoryPeerCap) : clamped, engaged)
    }
}

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
///
/// The cap only ever applies to a pool being created. It deliberately does *not* feed the
/// registry's fingerprint: recomputing it per flow used to tear down every live session the
/// moment a burst of traffic pushed headroom past the threshold.
nonisolated enum TurnMemory {

    /// Whether the low-memory session cap is currently engaged (hysteresis state).
    private static let capEngaged = Atomic<Bool>(false)

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
        let limit = TurnMemoryPolicy.goLimit(available: available)
        AnywhereConfigureMemory(limit, TurnMemoryPolicy.goGCPercent)
        logger.debug("TURN memory budget: \(available / (1 << 20)) MiB available, Go soft limit \(limit / (1 << 20)) MiB, GOGC \(TurnMemoryPolicy.goGCPercent)")
    }

    /// The session count to actually use, given the peers the user asked for and the
    /// headroom left. Each session carries its own DTLS/KCP state, so this is the most
    /// effective lever when memory is tight. Evaluated only when a pool is built.
    static func effectivePeers(requested: Int) -> Int {
        let available = availableBytes
        let wasEngaged = capEngaged.load(ordering: .relaxed)
        let result = TurnMemoryPolicy.peers(requested: requested, available: available, capActive: wasEngaged)
        capEngaged.store(result.capActive, ordering: .relaxed)
        if result.capActive {
            logger.info("TURN low memory (\(available / (1 << 20)) MiB): capping peers \(requested) → \(result.peers) for the new pool (live pools untouched)")
        } else if wasEngaged {
            logger.info("TURN memory recovered (\(available / (1 << 20)) MiB): peer cap lifted, new pools run \(result.peers)")
        }
        return result.peers
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
