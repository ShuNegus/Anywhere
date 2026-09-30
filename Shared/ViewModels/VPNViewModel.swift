//
//  VPNViewModel.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import NetworkExtension
import SwiftUI
import Observation

nonisolated private let logger = AnywhereLogger(category: "VPNViewModel")

@MainActor
@Observable
class VPNViewModel {
    static let shared = VPNViewModel()

    var vpnStatus: NEVPNStatus = .disconnected
    var selectedConfiguration: ProxyConfiguration? {
        didSet {
            if !_suppressSelectionPersistence {
                selectedChainId = nil
                AWCore.setSelectedChainId(nil)
                AWCore.setSelectedConfigurationId(selectedConfiguration?.id)
                RoutingRuleSetStore.shared.scheduleSyncToAppGroup()
            }
            if vpnStatus == .connected, let selectedConfiguration {
                sendConfigurationToTunnel(selectedConfiguration)
            }
        }
    }
    private(set) var selectedChainId: UUID?
    var latencyResults: [UUID: LatencyResult] = [:]
    var chainLatencyResults: [UUID: LatencyResult] = [:]
    /// TURN handshake phase reported by the tunnel, polled while connected. `nil` when
    /// the bypass is off or the extension has no dialer yet.
    private(set) var turnPhase: TurnPhase? = nil
    /// `TurnAutoState.Decision` raw value from the extension while the mode is `.auto`.
    private(set) var turnAutoDecision: String? = nil
    /// The bypass pools folded together: usable or not, peers up of the target, what the
    /// credential fetch is doing. `nil` while no dialer reports it (bypass off, or an
    /// older extension).
    private(set) var turnPool: TurnPoolSummary? = nil
    @ObservationIgnored private var turnPhaseTask: Task<Void, Never>?
    /// The captcha really came up during this session, so the graph shows the step as
    /// taken rather than skipped.
    private(set) var captchaSeenInSession = false
    /// The step the connection died on. Deliberately outlives the `.disconnected` that
    /// follows a failure — the red node has to stay on screen.
    private(set) var connectionFailure: ConnectionFailure?
    var startError: String?
    /// A reachability probe is running ahead of the tunnel; the button stays busy so a
    /// second tap cannot start the VPN behind the check.
    private(set) var isPreflighting = false

    /// Whether the tunnel ever reached `.connected` in this session: a `.disconnected`
    /// that arrives before it did is a failed start, not a normal teardown.
    @ObservationIgnored private var sessionReachedConnected = false
    @ObservationIgnored private var userRequestedDisconnect = false
    /// When the current step of the bypass started — the watchdog counts from here.
    /// Restarted whenever a credential set finishes or a new captcha comes up, so the
    /// budget below is per step, not for the whole connect.
    @ObservationIgnored private var turnRouteSince: ContinuousClock.Instant?
    /// Credential sets obtained as of the previous poll; a rise means a login finished.
    @ObservationIgnored private var lastTurnSetsObtained = -1
    /// Whether the previous poll was already inside a captcha — the edge into one is
    /// what restarts the clock.
    @ObservationIgnored private var lastTurnPhaseWasCaptcha = false
    /// `setsObtained` at the last captcha that restarted the clock: a captcha restarts it
    /// once per credential set, so an auto-solver failing in a loop still times out.
    @ObservationIgnored private var lastCaptchaRestartSets: Int? = nil
    @ObservationIgnored private var didAlertOffline = false
    /// The core's own `readyTimeout` is 30 s; these leave it room to retry once.
    /// Budget for *one* credential set, not for the whole connect.
    private static let turnReadyDeadline: Duration = .seconds(45)
    /// The auto solver is slower than the pool: give it its own, longer budget.
    /// Also per captcha — several sets mean several captchas in a row.
    private static let captchaAutoDeadline: Duration = .seconds(90)

    private(set) var isManagerReady = false
    @ObservationIgnored private var vpnManager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: Task<Void, Never>?
    private(set) var pendingReconnect = false
    /// The reconnect in flight was asked to go through TURN (a long press while connected).
    @ObservationIgnored private var pendingReconnectForcesTurn = false
    /// This session was forced through TURN by holding the power button, whatever the
    /// TURN mode says. Mirrors `AWCore.getTurnForced()`, which the extension reads.
    private(set) var turnForcedInSession = AWCore.getTurnForced()
    /// Debounces a transient `.reasserting` (network blip) while connected so the UI keeps
    /// showing "Connected" unless the reconnect persists past ``reassertingDebounceInterval``.
    @ObservationIgnored private var reassertingDebounceTask: Task<Void, Never>?
    private static let reassertingDebounceInterval: Duration = .seconds(5)
    /// Set only via `withoutSelectionPersistence` so the flag always resets.
    @ObservationIgnored private var _suppressSelectionPersistence = false

    /// Assigns `selectedConfiguration` without triggering the chain-clearing didSet branch.
    private func withoutSelectionPersistence(_ block: () -> Void) {
        _suppressSelectionPersistence = true
        defer { _suppressSelectionPersistence = false }
        block()
    }

    init() {
        restoreLatencyResults()
        setupStatusObserver()
        setupVPNManager()
    }

    // MARK: - Selection

    private func restoreSelection(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        guard selectedConfiguration == nil, selectedChainId == nil else { return }
        if let savedChainId = AWCore.getSelectedChainId(),
           let chain = chains.first(where: { $0.id == savedChainId }),
           let resolved = chain.resolveComposite(from: configurations) {
            selectedChainId = savedChainId
            withoutSelectionPersistence { selectedConfiguration = resolved }
        } else if let savedConfigurationId = AWCore.getSelectedConfigurationId(),
                  let configuration = configurations.first(where: { $0.id == savedConfigurationId }) {
            withoutSelectionPersistence { selectedConfiguration = configuration }
        } else {
            selectedConfiguration = configurations.first
        }
    }

    func revalidateSelection(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        if selectedConfiguration == nil, selectedChainId == nil {
            restoreSelection(configurations: configurations, chains: chains)
            return
        }
        if let chainId = selectedChainId {
            if let chain = chains.first(where: { $0.id == chainId }),
               let resolved = chain.resolveComposite(from: configurations) {
                withoutSelectionPersistence { selectedConfiguration = resolved }
            } else {
                selectedChainId = nil
                AWCore.setSelectedChainId(nil)
                selectedConfiguration = configurations.first
            }
        } else {
            if let selected = selectedConfiguration {
                if let refreshed = configurations.first(where: { $0.id == selected.id }) {
                    if refreshed != selected { selectedConfiguration = refreshed }
                } else {
                    selectedConfiguration = configurations.first
                }
            }
            if selectedConfiguration == nil {
                selectedConfiguration = configurations.first
            }
        }

        // The selection existed and is gone now (the subscription was deleted): there is
        // nothing left for the tunnel to carry. The restore path above returns earlier,
        // so a fresh launch — or a tunnel started from Settings / On Demand — is untouched.
        if selectedConfiguration == nil,
           vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
            disconnectVPN()
        }
    }

    func selectIfNone(_ configuration: ProxyConfiguration) {
        if selectedConfiguration == nil { selectedConfiguration = configuration }
    }

    // MARK: - Computed Properties

    var statusColor: Color {
        switch vpnStatus {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .yellow
        case .disconnecting:
            return .orange
        case .disconnected, .invalid:
            return .red
        @unknown default:
            return .gray
        }
    }
    
    var status: VPNStatus {
        VPNStatus(vpnStatus)
    }

    /// The raw value the extension reports, parsed back into the decision.
    var turnAutoDecisionValue: TurnAutoState.Decision? {
        turnAutoDecision.flatMap(TurnAutoState.Decision.init(rawValue:))
    }

    /// The captcha sheet came up: latch it for the rest of the session.
    func noteCaptchaSeen() {
        captchaSeenInSession = true
    }

    /// Records a failure once and surfaces it as an alert alongside the red node.
    private func noteFailure(_ failure: ConnectionFailure) {
        guard connectionFailure != failure else { return }
        connectionFailure = failure
        startError = failure.message
    }

    var statusText: String {
        status.localizedText
    }

    func isButtonDisabled(hasConfigurations: Bool) -> Bool {
        !isManagerReady || !hasConfigurations || vpnStatus.isTransitioning || isPreflighting
    }

    // MARK: - Chain Selection

    func selectChain(_ chain: ProxyChain, configurations: [ProxyConfiguration]) {
        guard let resolved = chain.resolveComposite(from: configurations) else { return }
        selectedChainId = chain.id
        AWCore.setSelectedChainId(chain.id)
        AWCore.setSelectedConfigurationId(nil)
        RoutingRuleSetStore.shared.scheduleSyncToAppGroup()
        withoutSelectionPersistence { selectedConfiguration = resolved }
    }

    // MARK: - Latency Testing

    @ObservationIgnored private var latencyTask: Task<Void, Never>?

    nonisolated private static let maxConcurrentLatencyTests = 8

    func testLatency(for configuration: ProxyConfiguration) {
        latencyTask?.cancel()
        let configurationId = configuration.id
        latencyResults[configurationId] = .testing
        let useIPC = vpnStatus == .connected
        latencyTask = Task { [weak self] in
            let result = await Self.runSingleLatencyTest(for: configuration, viaIPC: useIPC, session: useIPC ? self?.providerSession : nil)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.recordLatencyResult(result, for: configurationId)
            }
        }
    }

    func testLatencies(for targets: [ProxyConfiguration]) {
        latencyTask?.cancel()
        for config in targets {
            latencyResults[config.id] = .testing
        }
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        latencyTask = Task { [weak self] in
            await Self.runLatencyTests(targets, viaIPC: useIPC, session: session) { id, result in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.recordLatencyResult(result, for: id)
                }
            }
        }
    }

    // MARK: - Chain Latency Testing

    @ObservationIgnored private var chainLatencyTask: Task<Void, Never>?

    func testChainLatency(for chain: ProxyChain, configurations: [ProxyConfiguration]) {
        guard let resolved = chain.resolveComposite(from: configurations) else { return }
        chainLatencyResults[chain.id] = .testing
        let chainId = chain.id
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        chainLatencyTask?.cancel()
        chainLatencyTask = Task { [weak self] in
            let result = await Self.runSingleLatencyTest(for: resolved, viaIPC: useIPC, session: session)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.recordChainLatencyResult(result, for: chainId)
            }
        }
    }

    func testAllChainLatencies(chains: [ProxyChain], configurations: [ProxyConfiguration]) {
        chainLatencyTask?.cancel()
        var chainData: [(UUID, ProxyConfiguration)] = []
        for chain in chains {
            if let resolved = chain.resolveComposite(from: configurations) {
                chainLatencyResults[chain.id] = .testing
                chainData.append((chain.id, resolved))
            }
        }
        let chainIdByConfigId: [UUID: UUID] = Dictionary(uniqueKeysWithValues: chainData.map { ($0.1.id, $0.0) })
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        chainLatencyTask = Task { [weak self] in
            await Self.runLatencyTests(chainData.map(\.1), viaIPC: useIPC, session: session) { configId, result in
                if let chainId = chainIdByConfigId[configId] {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.recordChainLatencyResult(result, for: chainId)
                    }
                }
            }
        }
    }

    // MARK: - Latency Persistence
    
    @ObservationIgnored private var storedLatencyResults: [UUID: LatencyResult] = [:]
    @ObservationIgnored private var storedChainLatencyResults: [UUID: LatencyResult] = [:]

    private func restoreLatencyResults() {
        storedLatencyResults = Self.decodeLatencyResults(AWCore.getLatencyResultsData())
        storedChainLatencyResults = Self.decodeLatencyResults(AWCore.getChainLatencyResultsData())
        latencyResults = storedLatencyResults
        chainLatencyResults = storedChainLatencyResults
    }

    private func recordLatencyResult(_ result: LatencyResult, for configurationId: UUID) {
        latencyResults[configurationId] = result
        storedLatencyResults[configurationId] = result
        if let data = Self.encodeLatencyResults(storedLatencyResults) {
            AWCore.setLatencyResultsData(data)
        }
    }

    private func recordChainLatencyResult(_ result: LatencyResult, for chainId: UUID) {
        chainLatencyResults[chainId] = result
        storedChainLatencyResults[chainId] = result
        if let data = Self.encodeLatencyResults(storedChainLatencyResults) {
            AWCore.setChainLatencyResultsData(data)
        }
    }
    
    private static func encodeLatencyResults(_ results: [UUID: LatencyResult]) -> Data? {
        try? JSONEncoder().encode(results.mapValues { LatencyTestResponse($0) })
    }

    private static func decodeLatencyResults(_ data: Data?) -> [UUID: LatencyResult] {
        guard let data,
              let responses = try? JSONDecoder().decode([UUID: LatencyTestResponse].self, from: data) else {
            return [:]
        }
        return responses.mapValues { $0.asLatencyResult }
    }

    // MARK: - Latency Test Execution

    private var providerSession: NETunnelProviderSession? {
        vpnManager?.connection as? NETunnelProviderSession
    }

    nonisolated private static func runSingleLatencyTest(
        for configuration: ProxyConfiguration,
        viaIPC: Bool,
        session: NETunnelProviderSession?
    ) async -> LatencyResult {
        if viaIPC, let session {
            return await sendLatencyTestMessage(for: configuration, session: session)
        }
        return await LatencyTester.test(configuration)
    }

    /// Runs a batch of tests with at most `maxConcurrentLatencyTests` in flight, reporting each result as it arrives.
    nonisolated private static func runLatencyTests(
        _ configurations: [ProxyConfiguration],
        viaIPC: Bool,
        session: NETunnelProviderSession?,
        onResult: @Sendable @escaping (UUID, LatencyResult) async -> Void
    ) async {
        guard !configurations.isEmpty else { return }
        await withTaskGroup(of: (UUID, LatencyResult).self) { group in
            var iterator = configurations.makeIterator()
            for _ in 0..<min(Self.maxConcurrentLatencyTests, configurations.count) {
                if let config = iterator.next() {
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, viaIPC: viaIPC, session: session)
                        return (config.id, r)
                    }
                }
            }
            for await pair in group {
                await onResult(pair.0, pair.1)
                if let config = iterator.next() {
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, viaIPC: viaIPC, session: session)
                        return (config.id, r)
                    }
                }
            }
        }
    }

    /// Sends one `testLatency` IPC message and awaits the extension's reply. The extension
    /// resolves the address itself — main-app DNS while the tunnel is up yields lwIP fake IPs.
    nonisolated private static func sendLatencyTestMessage(
        for configuration: ProxyConfiguration,
        session: NETunnelProviderSession
    ) async -> LatencyResult {
        guard let messageData = try? JSONEncoder().encode(TunnelMessage.testLatency(configuration)) else { return .failed }

        let responseData = await ProviderMessageConcurrencyBridge.send(messageData, over: session)
        return (responseData.flatMap { try? JSONDecoder().decode(LatencyTestResponse.self, from: $0) })?.asLatencyResult ?? .failed
    }

    /// Returns `configuration` with `resolvedIP` set, preferring an existing value, then `fallback`,
    /// then a DNS lookup via the shared `DNSResolver` — on its blocking-resolve worker, so callers
    /// on the main actor or the cooperative pool never block on `getaddrinfo`.
    nonisolated static func withResolvedIP(
        _ configuration: ProxyConfiguration,
        fallback: String? = nil
    ) async -> ProxyConfiguration {
        if configuration.resolvedIP != nil { return configuration }
        let resolvedIP: String?
        if let fallback {
            resolvedIP = fallback
        } else {
            resolvedIP = await resolveServerAddress(configuration.serverAddress)
        }
        guard let resolved = resolvedIP else {
            return configuration
        }
        return ProxyConfiguration(
            id: configuration.id,
            name: configuration.name,
            serverAddress: configuration.serverAddress,
            serverPort: configuration.serverPort,
            resolvedIP: resolved,
            subscriptionId: configuration.subscriptionId,
            outbound: configuration.outbound,
            chain: configuration.chain
        )
    }

    // MARK: - Setup

    private func setupStatusObserver() {
        // The enclosing type is @MainActor, so this Task and `handleStatusChange` run on the
        // main actor.
        statusObserver = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard let connection = note.object as? NEVPNConnection,
                      connection === self.vpnManager?.connection else { continue }
                self.handleStatusChange(connection.status, on: connection)
            }
        }
    }

    /// Routes a raw tunnel status to the UI, debouncing a transient reconnect.
    private func handleStatusChange(_ status: NEVPNStatus, on connection: NEVPNConnection) {
        reassertingDebounceTask?.cancel()
        reassertingDebounceTask = nil

        if status == .reasserting, vpnStatus == .connected {
            reassertingDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.reassertingDebounceInterval)
                guard !Task.isCancelled, let self else { return }
                // Re-check the live status: apply only if it never recovered.
                guard connection.status == .reasserting else { return }
                self.applyStatus(.reasserting, on: connection)
            }
            return
        }

        applyStatus(status, on: connection)
    }

    /// Applies a tunnel status to `vpnStatus` and drives the stats-polling side effects.
    private func applyStatus(_ status: NEVPNStatus, on connection: NEVPNConnection) {
        let previous = vpnStatus
        vpnStatus = status
        let stats = ConnectionStatsModel.shared
        if status == .connected {
            sessionReachedConnected = true
            if connectionFailure == .vpnStartFailed { connectionFailure = nil }
            if let session = connection as? NETunnelProviderSession {
                stats.startPolling(session: session)
                startTurnPhaseWatch(session: session)
            }
        } else {
            stats.stopPolling()
            if status == .disconnected || status == .disconnecting || status == .invalid {
                stopTurnPhaseWatch()
            }
            if status == .disconnected || status == .invalid {
                // Dropped out of `.connecting` on its own: the tunnel never came up.
                if !sessionReachedConnected, !userRequestedDisconnect, previous == .connecting {
                    noteFailure(.vpnStartFailed)
                }
                stats.reset()
                if pendingReconnect {
                    pendingReconnect = false
                    // A reconnect keeps a forced TURN session forced.
                    let force = pendingReconnectForcesTurn || AWCore.getTurnForced()
                    pendingReconnectForcesTurn = false
                    connectVPN(forceTurn: force)
                }
            }
        }
    }

    // MARK: - TURN Phase

    private static let turnPhasePollInterval: Duration = .seconds(1)

    /// Polls the tunnel for the vk-turn core's connection phase, reusing the existing
    /// `fetchTurnStats` IPC. Keeps polling past `.ready`: the phase has to be able to
    /// fall back when a pool reconnects, so it is deliberately never latched.
    private func startTurnPhaseWatch(session: NETunnelProviderSession) {
        guard AWCore.getTurnActiveForSession(), AWCore.getEffectiveTurnMode() != .off else { return }
        guard turnPhaseTask == nil else { return }
        turnPhaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let status = await Self.fetchTurnStatus(session: session)
                guard let self else { return }
                self.turnPhase = status.phase
                self.turnAutoDecision = status.autoDecision
                self.turnPool = status.pool
                self.evaluateTurnProgress()
                try? await Task.sleep(for: Self.turnPhasePollInterval)
            }
        }
    }

    /// Latches the captcha and watches the bypass for a stall.
    ///
    /// The core has no failure phase of its own: a handshake that keeps failing simply
    /// loops `vkAccess → tunnelSetup → vkAccess`, and the phase can even move backwards.
    /// A deadline is the only way to call it.
    private func evaluateTurnProgress() {
        // The pool's fetch state is the precise signal; the phase is the fallback for an
        // extension that does not report it.
        let fetch = turnPool?.fetch
        let inCaptcha = fetch?.isCaptcha ?? (turnPhase == .captchaAuto || turnPhase == .captchaWait)
        let captchaWaitsForUser = fetch.map { $0 == .captchaWait } ?? (turnPhase == .captchaWait)
        if inCaptcha {
            captchaSeenInSession = true
        }
        // The core counts captchas, so one that solved itself between two polls is
        // still visible here — the latch above can miss it.
        if let captchas = turnPool?.captchas, captchas > 0 {
            captchaSeenInSession = true
        }

        // A login (and possibly its captcha) is one step and deserves the full budget;
        // the clock restarts whenever a set finishes or a fresh captcha comes up.
        var stepAdvanced = false
        if let obtained = turnPool?.setsObtained {
            if obtained > lastTurnSetsObtained { stepAdvanced = true }
            lastTurnSetsObtained = obtained
        }
        if inCaptcha && !lastTurnPhaseWasCaptcha {
            // Without the pool summary (older extension) every captcha edge counts, as before.
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
                startError = ConnectionFailure.networkLost.message
            }
            return
        }

        let mode = AWCore.getTurnActiveForSession() ? AWCore.getEffectiveTurnMode() : nil
        guard ConnectionStage.route(turnMode: mode, autoDecision: turnAutoDecisionValue) == .turn else {
            turnRouteSince = nil
            return
        }

        // The tunnel carries traffic: whatever the core still does — topping the pool up,
        // a captcha for more peers, a backoff — has no deadline, it retries on its own.
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

        if captchaWaitsForUser {
            // Waiting on the user, not on the tunnel — the clock does not apply.
            return
        }
        if inCaptcha {
            if now - since > Self.captchaAutoDeadline { noteFailure(.captchaTimeout) }
        } else if now - since > Self.turnReadyDeadline {
            noteFailure(.turnTimeout)
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
        // `connectionFailure` deliberately survives: the red node has to outlive the
        // `.disconnected` that follows the failure it describes.
    }

    /// The least-advanced phase across the live dialers: the graph should show the step
    /// the connection is still working on, not the one furthest along.
    private static func fetchTurnStatus(
        session: NETunnelProviderSession
    ) async -> (phase: TurnPhase?, autoDecision: String?, pool: TurnPoolSummary?) {
        guard session.status == .connected,
              let request = try? JSONEncoder().encode(TunnelMessage.fetchTurnStats),
              let response = await ProviderMessageConcurrencyBridge.send(request, over: session),
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

    private static let providerBundleIdentifier = "su.smd.Anywhere.Network-Extension"

    private func setupVPNManager() {
        Task {
            let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
            if let manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
            }) ?? managers?.first {
                self.vpnManager = manager
                self.vpnStatus = manager.connection.status
                if manager.connection.status == .connected,
                   let session = manager.connection as? NETunnelProviderSession {
                    ConnectionStatsModel.shared.startPolling(session: session)
                }
            } else {
                self.vpnManager = NETunnelProviderManager()
            }
            self.isManagerReady = true
        }
    }

    // MARK: - Actions

    func toggleVPN() {
        switch vpnStatus {
        case .connected, .connecting:
            disconnectVPN()
        case .disconnected, .invalid:
            connectVPN()
        default:
            break
        }
    }

    /// Connects through TURN whatever the TURN mode or the master switch says — the
    /// power button held for two seconds. Reconnects when the tunnel is already up.
    /// Refuses with an error when the selected server has no TURN relay or no VK link
    /// is known, rather than silently connecting directly.
    func connectForcingTurn() {
        guard let configuration = selectedConfiguration else { return }
        guard Self.isTurnAvailable(for: configuration) else {
            startError = String(
                localized: "vpn.error.turnUnavailable",
                defaultValue: "TURN is not available for this server: the subscription lists no relay for it, or no VK Calls link is set.",
                comment: "Долгое нажатие на кнопку: TURN для выбранного сервера недоступен"
            )
            return
        }
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            if AWCore.getTurnForced() { return } // already going through TURN
            pendingReconnectForcesTurn = true
            reconnectVPN()
        case .disconnected, .invalid:
            connectVPN(forceTurn: true)
        default:
            break
        }
    }

    /// The selected server has a usable TURN relay in a subscription and there is a VK
    /// link to dial with — what the extension will need to open the tunnel.
    static func isTurnAvailable(for configuration: ProxyConfiguration) -> Bool {
        guard let server = TurnMetadataStore.shared.server(for: configuration.serverAddress),
              server.isUsable else { return false }
        let manual = AWCore.getTurnVKLink().trimmingCharacters(in: .whitespacesAndNewlines)
        let shipped = TurnMetadataStore.shared.subscriptionVKLink()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !manual.isEmpty || !shipped.isEmpty
    }

    /// - Parameter forceTurn: route this session through TURN whatever the mode says.
    ///   An ordinary connect clears a previous session's force.
    func connectVPN(forceTurn: Bool = false) {
        guard let manager = vpnManager,
              let configuration = selectedConfiguration else { return }

        // Before anything reads the mode below (the preflight) or in the extension.
        AWCore.setTurnForced(forceTurn)
        turnForcedInSession = forceTurn

        connectionFailure = nil
        captchaSeenInSession = false
        userRequestedDisconnect = false
        sessionReachedConnected = false

        Task { [self] in
            // Auto mode is the only one that probes: it is also the only one that has to
            // tell "no network" apart from "censored network", and refusing to start on a
            // dead network beats a tunnel that silently carries nothing.
            if AWCore.getTurnActiveForSession(), AWCore.getEffectiveTurnMode() == .auto {
                isPreflighting = true
                let verdict = await ConnectivityProbe.classify(profile: .preflight)
                isPreflighting = false
                // Handed to the extension: its own first probe, a second or two later,
                // has this to check itself against before it commits to the relay.
                AWCore.setPreflightVerdict(verdict)
                if verdict == .offline {
                    noteFailure(.noNetwork)
                    return
                }
            }

            // Resolves on DNSResolver's worker queue, off both the main actor and
            // the cooperative pool.
            let resolvedIP = await VPNViewModel.resolveServerAddress(configuration.serverAddress)

            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = "su.smd.Anywhere.Network-Extension"
            tunnelProtocol.serverAddress = "Anywhere"
            #if !os(tvOS)
            tunnelProtocol.includeAllNetworks = AWCore.getTunnelIncludeAllNetworks()
            tunnelProtocol.excludeLocalNetworks = !AWCore.getTunnelIncludeLocalNetworks()
            tunnelProtocol.excludeAPNs = !AWCore.getTunnelIncludeAPNs()
            tunnelProtocol.excludeCellularServices = !AWCore.getTunnelIncludeCellularServices()
            #endif

            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = "Anywhere"
            manager.isEnabled = true

            let alwaysOn = AWCore.getAlwaysOnEnabled()
            if alwaysOn {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
            } else {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
            }

            do {
                try await manager.saveToPreferences()
                // Reload so the connection reference is valid after the save round-trip.
                try await manager.loadFromPreferences()

                let resolved = await Self.withResolvedIP(configuration, fallback: resolvedIP)

                // Persist to App Group so the NE can read it when started from Settings or On Demand, where options is nil.
                if let configData = try? JSONEncoder().encode(resolved) {
                    AWCore.setLastConfigurationData(configData)
                }

                let messageData = try JSONEncoder().encode(TunnelMessage.setConfiguration(resolved))
                try manager.connection.startVPNTunnel(options: [TunnelMessage.optionKey: messageData as NSObject])
            } catch {
                self.startError = error.localizedDescription
                self.connectionFailure = .vpnStartFailed
            }
        }
    }

    func disconnectVPN() {
        guard let manager = vpnManager else { return }
        userRequestedDisconnect = true
        // A forced TURN session ends with it; Always On restarts go by the mode again.
        AWCore.setTurnForced(false)
        turnForcedInSession = false
        // Clear any pending reconnect — an explicit disconnect should not auto-reconnect
        pendingReconnect = false
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            Task {
                try? await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    func reconnectVPN() {
        guard let manager = vpnManager,
              vpnStatus == .connected || vpnStatus == .connecting else { return }
        userRequestedDisconnect = true
        pendingReconnect = true
        // Disable on-demand first to prevent system auto-restart during reconnection
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            Task {
                try? await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    // MARK: - Configuration Switching

    private func sendConfigurationToTunnel(_ configuration: ProxyConfiguration) {
        guard let session = vpnManager?.connection as? NETunnelProviderSession else { return }

        Task.detached {
            let resolved = await Self.withResolvedIP(configuration)

            // Keep App Group in sync so On Demand restarts use the latest selection.
            if let configData = try? JSONEncoder().encode(resolved) {
                AWCore.setLastConfigurationData(configData)
            }

            guard let data = try? JSONEncoder().encode(TunnelMessage.setConfiguration(resolved)) else { return }
            _ = await ProviderMessageConcurrencyBridge.send(data, over: session)
        }
    }

    // MARK: - DNS Resolution

    /// Resolves a server address to an IP string (IP literals pass through) via the
    /// shared `DNSResolver`, so proxy lookups share the transport layers' cache. The
    /// blocking lookup runs on the resolver's worker queue, not the caller's thread.
    nonisolated static func resolveServerAddress(_ address: String) async -> String? {
        await DNSResolver.shared.resolveHost(address)
    }

}

extension NEVPNStatus {
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}

extension VPNStatus {
    /// Unknown future tunnel states read as `.invalid`.
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }
}
