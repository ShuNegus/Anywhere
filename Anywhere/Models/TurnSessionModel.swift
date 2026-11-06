//
//  TurnSessionModel.swift
//  Anywhere
//
//  The backup route (TURN) side of a VPN session, on top of upstream's
//  TunnelController: the forced-TURN flag the extension reads, the pre-flight probe,
//  the phase poll and the watchdog that gives up on TURN for the session. Ported
//  from the old VPNViewModel when upstream 2.6 replaced it.
//

import Foundation
import NetworkExtension
import Observation

nonisolated private let logger = AnywhereLogger(category: "TurnSession")

@MainActor
@Observable
final class TurnSessionModel {
    /// TURN handshake phase reported by the tunnel, polled while connected. `nil` when
    /// the bypass is off or the extension has no dialer yet.
    private(set) var turnPhase: TurnPhase?
    /// `TurnAutoState.Decision` raw value from the extension while the mode is `.auto`.
    private(set) var turnAutoDecision: String?
    /// The bypass pools folded together; `nil` while no dialer reports it.
    private(set) var turnPool: TurnPoolSummary?
    /// The captcha really came up during this session.
    private(set) var captchaSeenInSession = false
    /// The step the connection died on. Outlives the `.disconnected` that follows a
    /// failure — the red node has to stay on screen.
    private(set) var connectionFailure: ConnectionFailure?
    /// The backup route was needed but did not come up in time: TURN is suppressed for
    /// the rest of the session and traffic goes direct.
    private(set) var runtimeBypassFailure: TurnUnavailableReason?
    /// Mode «Off», and the pre-flight probe found the direct route censored.
    private(set) var bypassNeededWhileOff = false
    /// A reachability probe is running ahead of the tunnel.
    private(set) var isPreflighting = false
    /// This session was forced through TURN (power button held). Mirrors
    /// `AWCore.getTurnForced()`, which the extension reads.
    private(set) var turnForcedInSession = AWCore.getTurnForced()

    @ObservationIgnored private let tunnel: TunnelController
    @ObservationIgnored private let selection: ProxySelection
    @ObservationIgnored private let subscriptionStore: SubscriptionStore

    @ObservationIgnored private var previousStatus: NEVPNStatus = .invalid
    @ObservationIgnored private var sessionReachedConnected = false
    @ObservationIgnored private var userRequestedDisconnect = false
    @ObservationIgnored private var turnPhaseTask: Task<Void, Never>?
    @ObservationIgnored private var turnRouteSince: ContinuousClock.Instant?
    @ObservationIgnored private var lastTurnSetsObtained = -1
    @ObservationIgnored private var lastTurnPhaseWasCaptcha = false
    @ObservationIgnored private var lastCaptchaRestartSets: Int?
    @ObservationIgnored private var didAlertOffline = false
    @ObservationIgnored private var started = false

    /// The core's own `readyTimeout` is 30 s; these leave it room to retry once. Per
    /// credential set (one login, possibly with its captcha), not for the whole connect.
    private static let turnReadyDeadline: Duration = .seconds(45)
    private static let captchaAutoDeadline: Duration = .seconds(90)
    private static let turnPhasePollInterval: Duration = .seconds(1)

    init(tunnel: TunnelController, selection: ProxySelection, subscriptionStore: SubscriptionStore) {
        self.tunnel = tunnel
        self.selection = selection
        self.subscriptionStore = subscriptionStore
    }

    func start() {
        guard !started else { return }
        started = true
        previousStatus = tunnel.rawStatus
        observeStatus()
        if tunnel.rawStatus == .connected { handleStatus(.connected) }
    }

    // MARK: - Connect / disconnect

    /// Ordinary connect: runs the pre-flight probe the mode asks for, then starts the
    /// tunnel. Clears a previous session's forced TURN.
    func connect(forceTurn: Bool = false) {
        guard let configuration = selection.selectedConfiguration else { return }
        // Before anything reads the mode below (the preflight) or in the extension.
        AWCore.setTurnForced(forceTurn)
        turnForcedInSession = forceTurn

        connectionFailure = nil
        captchaSeenInSession = false
        userRequestedDisconnect = false
        sessionReachedConnected = false
        runtimeBypassFailure = nil
        bypassNeededWhileOff = false
        AWCore.setTurnSuppressed(false)

        Task { [self] in
            if AWCore.getTurnActiveForSession(), AWCore.getEffectiveTurnMode() == .auto {
                // Auto mode also has to tell "no network" from "censored network":
                // refusing to start on a dead network beats a tunnel carrying nothing.
                isPreflighting = true
                let verdict = await ConnectivityProbe.classify(profile: .preflight)
                isPreflighting = false
                // The extension's own first probe checks itself against this one.
                AWCore.setPreflightVerdict(verdict)
                if verdict == .offline {
                    noteFailure(.noNetwork)
                    return
                }
            } else if AWCore.getTurnFeatureEnabled(), !forceTurn, AWCore.getTurnMode() == .off {
                // Mode «Off» never uses the backup route, but says so when it would have
                // been needed. Informational only.
                isPreflighting = true
                let verdict = await ConnectivityProbe.classify(profile: .preflight)
                isPreflighting = false
                bypassNeededWhileOff = verdict == .blocked
            }
            tunnel.connect(using: selection.selectedConfiguration ?? configuration)
        }
    }

    /// The power button held for two seconds: through TURN whatever the mode says.
    /// Reconnects when the tunnel is already up. Without a usable relay it still
    /// connects — directly — and `bypassUnavailableReason` says why in red.
    func connectForcingTurn() {
        guard selection.selectedConfiguration != nil else { return }
        switch tunnel.rawStatus {
        case .connected, .connecting, .reasserting:
            if AWCore.getTurnForced() { return } // already going through TURN
            AWCore.setTurnForced(true)
            turnForcedInSession = true
            noteUserReconnect()
            tunnel.reconnect()
        case .disconnected, .invalid:
            connect(forceTurn: true)
        default:
            break
        }
    }

    func noteUserDisconnect() {
        userRequestedDisconnect = true
        // A forced TURN session ends with it; Always On restarts go by the mode again.
        AWCore.setTurnForced(false)
        turnForcedInSession = false
    }

    /// A reconnect keeps a forced TURN session forced (the flag stays in the app group).
    func noteUserReconnect() {
        userRequestedDisconnect = true
    }

    func noteCaptchaSeen() {
        captchaSeenInSession = true
    }

    var turnAutoDecisionValue: TurnAutoState.Decision? {
        turnAutoDecision.flatMap(TurnAutoState.Decision.init(rawValue:))
    }

    /// Why the selected server cannot use the backup route right now, if it were needed.
    var bypassUnavailableReason: TurnUnavailableReason? {
        guard let configuration = selection.selectedConfiguration,
              configuration.chain?.isEmpty ?? true else { return nil }
        let forced = turnForcedInSession
        let mode: TurnMode? = forced ? .on : (AWCore.getTurnFeatureEnabled() ? AWCore.getTurnMode() : nil)
        let subscriptionId = configuration.subscriptionId
        let manual = AWCore.getTurnVKLink().trimmingCharacters(in: .whitespacesAndNewlines)
        let shipped = TurnMetadataStore.shared.subscriptionVKLink()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TurnAvailabilityPolicy.connectionReason(
            mode: mode,
            forced: forced,
            availability: subscriptionId.flatMap { subscriptionStore.backupRoute(for: $0) },
            metadata: subscriptionId.flatMap { TurnMetadataStore.shared.metadata(forSubscription: $0) },
            serverHost: configuration.serverAddress,
            hasVKLink: !manual.isEmpty || !shipped.isEmpty
        )
    }

    // MARK: - Status

    private func observeStatus() {
        withObservationTracking {
            _ = tunnel.rawStatus
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleStatus(self.tunnel.rawStatus)
                self.observeStatus()
            }
        }
    }

    private func handleStatus(_ status: NEVPNStatus) {
        let previous = previousStatus
        previousStatus = status
        if status == .connected {
            sessionReachedConnected = true
            if connectionFailure == .vpnStartFailed { connectionFailure = nil }
            startTurnPhaseWatch()
            return
        }
        if status == .disconnected || status == .disconnecting || status == .invalid {
            stopTurnPhaseWatch()
        }
        if status == .disconnected || status == .invalid {
            // Dropped out of `.connecting` on its own: the tunnel never came up.
            if !sessionReachedConnected, !userRequestedDisconnect, previous == .connecting {
                noteFailure(.vpnStartFailed)
            }
        }
    }

    private func noteFailure(_ failure: ConnectionFailure) {
        guard connectionFailure != failure else { return }
        connectionFailure = failure
        tunnel.startError = failure.message
    }

    // MARK: - TURN phase watch

    private func startTurnPhaseWatch() {
        guard AWCore.getTurnActiveForSession(), AWCore.getEffectiveTurnMode() != .off else { return }
        guard turnPhaseTask == nil else { return }
        turnPhaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.fetchTurnStatus()
                self.turnPhase = status.phase
                self.turnAutoDecision = status.autoDecision
                self.turnPool = status.pool
                self.evaluateTurnProgress()
                try? await Task.sleep(for: Self.turnPhasePollInterval)
            }
        }
    }

    private func stopTurnPhaseWatch() {
        turnPhaseTask?.cancel()
        turnPhaseTask = nil
        turnPhase = nil
        turnAutoDecision = nil
        turnPool = nil
        turnRouteSince = nil
        lastTurnSetsObtained = -1
        lastTurnPhaseWasCaptcha = false
        lastCaptchaRestartSets = nil
        didAlertOffline = false
        captchaSeenInSession = false
    }

    /// The core has no failure phase: a handshake that keeps failing loops and the phase
    /// can move backwards. A deadline per step is the only way to call it.
    private func evaluateTurnProgress() {
        let fetch = turnPool?.fetch
        let inCaptcha = fetch?.isCaptcha ?? (turnPhase == .captchaAuto || turnPhase == .captchaWait)
        let captchaWaitsForUser = fetch.map { $0 == .captchaWait } ?? (turnPhase == .captchaWait)
        if inCaptcha { captchaSeenInSession = true }
        if let captchas = turnPool?.captchas, captchas > 0 { captchaSeenInSession = true }

        var stepAdvanced = false
        if let obtained = turnPool?.setsObtained {
            if obtained > lastTurnSetsObtained { stepAdvanced = true }
            lastTurnSetsObtained = obtained
        }
        if inCaptcha && !lastTurnPhaseWasCaptcha {
            let sets = turnPool?.setsObtained
            if sets == nil || sets != lastCaptchaRestartSets {
                stepAdvanced = true
                lastCaptchaRestartSets = sets
            }
        }
        lastTurnPhaseWasCaptcha = inCaptcha

        if turnAutoDecisionValue == .offline {
            if !didAlertOffline {
                didAlertOffline = true
                tunnel.startError = ConnectionFailure.networkLost.message
            }
            return
        }

        if runtimeBypassFailure != nil { return }
        if bypassUnavailableReason != nil { turnRouteSince = nil; return }

        let mode = AWCore.getTurnActiveForSession() ? AWCore.getEffectiveTurnMode() : nil
        guard ConnectionStage.route(turnMode: mode, autoDecision: turnAutoDecisionValue) == .turn else {
            turnRouteSince = nil
            return
        }

        // The tunnel carries traffic: whatever the core still does has no deadline.
        if turnPool?.usable ?? (turnPhase == .ready) {
            if connectionFailure == .turnTimeout || connectionFailure == .captchaTimeout {
                connectionFailure = nil
            }
            turnRouteSince = nil
            return
        }

        let now = ContinuousClock.now
        let since = stepAdvanced ? now : (turnRouteSince ?? now)
        turnRouteSince = since

        if captchaWaitsForUser { return }
        if inCaptcha {
            if now - since > Self.captchaAutoDeadline { giveUpOnBypass(inCaptcha: true) }
        } else if now - since > Self.turnReadyDeadline {
            giveUpOnBypass(inCaptcha: false)
        }
    }

    /// Route the rest of the session direct (the extension stops dialling TURN and
    /// closes its pools) and say why, in red.
    private func giveUpOnBypass(inCaptcha: Bool) {
        let reason = TurnAvailabilityPolicy.runtimeReason(inCaptcha: inCaptcha)
        logger.info("Backup route did not come up (\(reason.rawValue)); continuing direct")
        AWCore.setTurnSuppressed(true)
        runtimeBypassFailure = reason
        turnRouteSince = nil
    }

    /// The least-advanced phase across the live dialers.
    private func fetchTurnStatus() async -> (phase: TurnPhase?, autoDecision: String?, pool: TurnPoolSummary?) {
        guard tunnel.rawStatus == .connected,
              let response = await tunnel.send(.fetchTurnStats),
              let stats = try? JSONDecoder().decode(TurnStatsResponse.self, from: response) else {
            return (nil, nil, nil)
        }
        let phases = stats.hosts
            .compactMap(\.phase)
            .compactMap(TurnPhase.init(rawValue:))
            .filter { $0 != .inactive }
        let phase = phases.min(by: { $0.rawValue < $1.rawValue })
            ?? (stats.totalSessions > 0 ? .ready : nil)
        return (phase, stats.autoDecision, TurnPoolSummary(combining: stats.hosts.compactMap(\.core)))
    }
}
