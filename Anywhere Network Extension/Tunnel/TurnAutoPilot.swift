//
//  TurnAutoPilot.swift
//  Anywhere Network Extension
//

import Foundation
import Network
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnAutoPilot")

/// The identity of the network the device is on, as far as the auto pilot cares.
///
/// `NWPathMonitor` fires generously — Wi-Fi roaming between access points, a channel
/// change, IPv6 appearing or disappearing, DNS servers being re-advertised — and every
/// one of those events used to trigger a fresh probe on an unchanged network. The
/// fingerprint keeps only the properties that actually say "this is a different
/// network"; `supportsIPv6`, `isExpensive` and the DNS list are deliberately excluded,
/// because those are exactly the fields that flap while standing still.
nonisolated struct NetworkFingerprint: Equatable, CustomStringConvertible, Sendable {

    enum InterfaceKind: String, Sendable {
        case wifi, cellular, wired, other
    }

    let interfaceKind: InterfaceKind
    let interfaceName: String?
    /// Wi-Fi only, and the strongest signal available: two networks on the same `en0`
    /// are the same network exactly when the SSID matches.
    let ssid: String?
    /// Stand-in for the SSID when it could not be read (entitlement denied, location
    /// services off, cellular). Compared only in that case — on Wi-Fi a gateway change
    /// is routine, and it must not masquerade as a network change.
    let gatewayFallback: String?

    init(interfaceKind: InterfaceKind, interfaceName: String?, ssid: String?, gatewayFallback: String?) {
        self.interfaceKind = interfaceKind
        self.interfaceName = interfaceName
        self.ssid = ssid
        self.gatewayFallback = gatewayFallback
    }

    init(path: Network.NWPath, ssid: String?) {
        let primary = path.availableInterfaces.first
        let kind: InterfaceKind = switch primary?.type {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wired
        default: .other
        }
        self.interfaceKind = kind
        self.interfaceName = primary?.name
        self.ssid = kind == .wifi ? ssid : nil
        let gateways = path.gateways.map(\.debugDescription).sorted()
        self.gatewayFallback = gateways.isEmpty ? nil : gateways.joined(separator: ",")
    }

    static func == (lhs: NetworkFingerprint, rhs: NetworkFingerprint) -> Bool {
        guard lhs.interfaceKind == rhs.interfaceKind,
              lhs.interfaceName == rhs.interfaceName,
              lhs.ssid == rhs.ssid else { return false }
        // Both sides have the same SSID; when that is a real name it already settles it.
        guard lhs.ssid == nil else { return true }
        return lhs.gatewayFallback == rhs.gatewayFallback
    }

    var description: String {
        var parts = [interfaceKind.rawValue]
        if let interfaceName { parts.append(interfaceName) }
        if let ssid { parts.append("ssid=\(ssid)") }
        else if let gatewayFallback { parts.append("gw=\(gatewayFallback)") }
        return parts.joined(separator: "/")
    }
}

/// Decides, inside the tunnel process, whether flows go direct or through TURN — and
/// keeps deciding as the device moves between networks.
///
/// The probe runs alongside the tunnel coming up rather than before it, so a network that
/// needs no bypass pays nothing for the check; flows that get there first wait on
/// `TurnAutoState`. A move onto a censored network is caught by the path-change hook,
/// because the first probe's answer stops being true the moment the Wi-Fi changes.
///
/// Switching to the relay is expensive and, once done, sticky for the session, so the
/// bar for it is deliberately high: the network must have actually changed, and a
/// `blocked` verdict on a network that was working has to repeat before it counts.
nonisolated final class TurnAutoPilot: Sendable {

    /// Path updates arrive in bursts while an interface settles; probing on the first one
    /// would measure a half-configured network.
    private static let networkChangeDebounce: Duration = .milliseconds(1500)
    /// How many consecutive `blocked` verdicts it takes to abandon a working direct path.
    private static let blockedConfirmations = 3
    /// Gap between those confirmations — long enough for a transient outage to pass,
    /// short enough that a genuinely censored network is caught within a minute.
    private static let confirmationDelay: Duration = .seconds(12)
    /// How old the app's pre-flight verdict may be and still describe this network.
    private static let preflightMaxAge: TimeInterval = 30
    /// Gap before the one re-check that settles a first probe contradicting the
    /// pre-flight. Short: flows are still waiting on the decision.
    private static let crossCheckDelay: Duration = .milliseconds(2500)

    private struct State {
        var probe: Task<Void, Never>?
        var pending: Task<Void, Never>?
        /// Bumped on every scheduled probe so a burst of path events leaves one survivor.
        var generation: UInt64 = 0
        /// The network the last probe was about. `nil` until the first path event.
        var lastFingerprint: NetworkFingerprint?
        /// Consecutive `blocked` verdicts seen while the decision was `.direct`.
        var blockedStreak = 0
        /// Whether the probe now being scheduled follows a real network change; carried
        /// through so the decision log can say why the probe ran.
        var fingerprintChanged = false
        /// Whether the session's first `blocked` verdict has already been re-checked
        /// against the app's pre-flight. One re-check per session, never more.
        var didCrossCheckPreflight = false
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
                state.lastFingerprint = nil
                state.blockedStreak = 0
                state.fingerprintChanged = false
                state.didCrossCheckPreflight = false
            }
            return (state.probe, state.pending)
        }
        probe?.cancel()
        pending?.cancel()
        onSwitchToTurn.withLock { $0 = nil }
        TurnAutoState.shared.reset()
    }

    /// A path event arrived. Re-probe only when the network behind it is genuinely a
    /// different one — or when there is no decision worth keeping.
    ///
    /// `fingerprint` is `nil` when the caller has no path in hand (waking from sleep).
    func noteNetworkChange(fingerprint: NetworkFingerprint?) {
        guard isEngaged else { return }
        // `.turn` is terminal for the session — the pools are up and re-deciding would
        // only tear down working streams.
        let decision = TurnAutoState.shared.decision
        guard decision != .turn else { return }
        let isDecided = decision != .undecided && decision != .offline

        guard let fingerprint else {
            // Woken up with no path to look at. A settled decision is more likely still
            // right than a probe run against a network that may not be up yet.
            guard !isDecided else {
                logger.info("[TURN auto] wake, decision=\(decision.rawValue) already settled — not re-probing")
                return
            }
            schedule(after: Self.networkChangeDebounce)
            return
        }

        let changed = state.withLock { state -> Bool in
            guard state.lastFingerprint != fingerprint else { return false }
            state.lastFingerprint = fingerprint
            state.blockedStreak = 0
            state.fingerprintChanged = true
            return true
        }

        guard changed || !isDecided else {
            logger.info("[TURN auto] path event on the same network (\(fingerprint)), decision=\(decision.rawValue) — not re-probing")
            return
        }
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

    /// True when the app probed this very network a moment ago and found it open. The
    /// two answers cannot both be right, and the cheap one to get wrong is ours: a
    /// single lost handshake here would move the whole session onto the relay. Consumes
    /// the allowance, so the re-check decides for itself.
    private func shouldCrossCheckAgainstPreflight() -> Bool {
        guard AWCore.getRecentPreflightVerdict(maxAge: Self.preflightMaxAge) == .open else { return false }
        return state.withLock { state -> Bool in
            guard !state.didCrossCheckPreflight else { return false }
            state.didCrossCheckPreflight = true
            return true
        }
    }

    private func probe() async {
        guard isEngaged else { return }
        let previous = TurnAutoState.shared.decision
        let fingerprintChanged = state.withLock { state -> Bool in
            defer { state.fingerprintChanged = false }
            return state.fingerprintChanged
        }
        let verdict = await ConnectivityProbe.classify(profile: .background)
        guard isEngaged else { return }

        switch verdict {
        case .open:
            state.withLock { $0.blockedStreak = 0 }
            TurnAutoState.shared.setDecision(.direct)

        case .blocked:
            // Only a *switch* rebuilds the outbound state; the first probe of a session
            // has no live direct connections to tear down, so it normally decides on the
            // spot — flows wait at most three seconds for it.
            guard previous == .direct else {
                if shouldCrossCheckAgainstPreflight() {
                    logger.info("[TURN auto] first probe says blocked but the app's pre-flight said open — re-checking before committing")
                    schedule(after: Self.crossCheckDelay)
                    return
                }
                TurnAutoState.shared.setDecision(.turn)
                return
            }
            let streak = state.withLock { state -> Int in
                state.blockedStreak += 1
                return state.blockedStreak
            }
            guard streak >= Self.blockedConfirmations else {
                logger.info("[TURN auto] blocked verdict \(streak)/\(Self.blockedConfirmations) on a working network (changed=\(fingerprintChanged)), keeping direct and re-checking")
                schedule(after: Self.confirmationDelay)
                return
            }
            logger.info("[TURN auto] network became censored, moving flows onto the relay")
            TurnAutoState.shared.setDecision(.turn)
            onSwitchToTurn.withLock { $0 }?()

        case .offline:
            // Nothing answered at all — not even the domestic hosts a censored network
            // leaves alone. That is a saturated or dropping network, not a verdict about
            // censorship, so a route that is already working stays.
            guard previous == .direct || previous == .turn else {
                // No route to keep: release the flows rather than hold them hostage.
                TurnAutoState.shared.setDecision(.offline)
                return
            }
            logger.info("[TURN auto] probe indeterminate (nothing answered), keeping \(previous.rawValue)")
        }
    }
}
