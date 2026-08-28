//
//  TurnAutoPilot.swift
//  Anywhere Network Extension
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnAutoPilot")

/// Decides, inside the tunnel process, whether flows go direct or through TURN — and
/// keeps deciding as the device moves between networks.
///
/// The probe runs alongside the tunnel coming up rather than before it, so a network that
/// needs no bypass pays nothing for the check; flows that get there first wait on
/// `TurnAutoState`. A move onto a censored network is caught by the path-change hook,
/// because the first probe's answer stops being true the moment the Wi-Fi changes.
nonisolated final class TurnAutoPilot: Sendable {

    /// Path updates arrive in bursts while an interface settles; probing on the first one
    /// would measure a half-configured network.
    private static let networkChangeDebounce: Duration = .milliseconds(1500)

    private struct State {
        var probe: Task<Void, Never>?
        var pending: Task<Void, Never>?
        /// Bumped on every scheduled probe so a burst of path events leaves one survivor.
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())
    private let onSwitchToTurn = Mutex<(@Sendable () -> Void)?>(nil)

    /// Probes immediately. No-op unless the feature is on and the mode is `.auto`.
    func start(onSwitchToTurn handler: @escaping @Sendable () -> Void) {
        guard isEngaged else { return }
        self.onSwitchToTurn.withLock { $0 = handler }
        schedule(after: nil)
    }

    func stop() {
        let (probe, pending) = state.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            defer {
                state.probe = nil
                state.pending = nil
                state.generation &+= 1
            }
            return (state.probe, state.pending)
        }
        probe?.cancel()
        pending?.cancel()
        onSwitchToTurn.withLock { $0 = nil }
        TurnAutoState.shared.reset()
    }

    /// The interface changed: re-probe unless TURN is already carrying the traffic.
    func noteNetworkChange() {
        guard isEngaged else { return }
        // `.turn` is terminal for the session — the pools are up and re-deciding would
        // only tear down working streams.
        guard TurnAutoState.shared.decision != .turn else { return }
        schedule(after: Self.networkChangeDebounce)
    }

    // MARK: - Private

    private var isEngaged: Bool {
        AWCore.getTurnFeatureEnabled() && AWCore.getTurnMode() == .auto
    }

    private func schedule(after delay: Duration?) {
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            state.pending?.cancel()
            return state.generation
        }

        let pending = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self, self.isCurrent(generation) else { return }
            await self.probe()
        }
        state.withLock { $0.pending = pending }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    private func probe() async {
        guard isEngaged else { return }
        let previous = TurnAutoState.shared.decision
        let verdict = await ConnectivityProbe.classify()
        guard isEngaged else { return }

        switch verdict {
        case .open:
            TurnAutoState.shared.setDecision(.direct)
        case .blocked:
            TurnAutoState.shared.setDecision(.turn)
            // Only a *switch* rebuilds the outbound state; the first probe of a session
            // has no live direct connections to tear down.
            if previous == .direct {
                logger.info("[TURN auto] network became censored, moving flows onto the relay")
                onSwitchToTurn.withLock { $0 }?()
            }
        case .offline:
            // Nothing answered. Do not commit to a route: leave the decision open so the
            // next path change probes again, but release the flows that are waiting.
            TurnAutoState.shared.setDecision(.offline)
        }
    }
}
