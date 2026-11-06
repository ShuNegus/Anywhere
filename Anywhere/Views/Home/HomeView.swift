//
//  HomeView.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import SwiftUI
import NetworkExtension

struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Operations.self) private var operations
    @Environment(TunnelController.self) private var tunnel
    @Environment(TurnSessionModel.self) private var turnSession
    @Environment(ProxySelection.self) private var selection
    @Environment(LatencyCenter.self) private var latency
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(SubscriptionStore.self) private var subscriptionStore
    
    private static let horizontalPadding: CGFloat = 16
    private static let maxControlPaneWidth: CGFloat = 500
    /// Clears the last row from under ``tabBarScrim`` (112 tall) when scrolled to the end.
    private static let scrollBottomInset: CGFloat = 96

    @State private var connectionEffectsEnabled = false

    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false
    @State private var showingStatsSheet = false

    @State private var captchaMonitor = TurnCaptchaMonitor.shared
    /// Deleting a subscription is destructive, so it goes through a confirmation.
    @State private var subscriptionPendingDeletion: Subscription?
    /// Subscription being refreshed from its header button; one at a time.
    @State private var refreshingSubscription: UUID?
    @State private var subscriptionRefreshError: String?

    private var isLoading: Bool { !configStore.isLoaded }

    private var isConnected: Bool {
        #if DEBUG
        if let demo = DebugBackupRouteSeed.demoStage { return demo.isConnected }
        #endif
        return tunnel.rawStatus == .connected
    }

    private var isTransitioning: Bool { tunnel.rawStatus.isTransitioning || turnSession.isPreflighting }

    /// Same rule as upstream's power button, plus our TURN preflight.
    private var isPowerButtonDisabled: Bool {
        isLoading || !configStore.hasConfigurations || isTransitioning || !tunnel.isManagerReady
    }

    /// Stage for the connection graph. The route comes from the setting (in `.auto`,
    /// from the probe's verdict); the captcha monitor stays in as an independent signal
    /// because it fires the moment the sheet comes up, ahead of the next phase poll.
    private var stage: ConnectionStage {
        #if DEBUG
        if let demo = DebugBackupRouteSeed.demoStage { return demo }
        #endif
        return ConnectionStage.resolve(
            status: tunnel.status,
            isPreflighting: turnSession.isPreflighting,
            // A session forced through TURN (power button held) walks the bypass branch
            // whatever the setting says.
            turnMode: turnSession.turnForcedInSession ? .on : (settings.turnFeatureEnabled ? settings.turnMode : nil),
            autoDecision: turnSession.turnAutoDecisionValue,
            turnPhase: turnSession.turnPhase,
            turnUsable: turnSession.turnPool?.usable,
            captchaPending: captchaMonitor.captchaWaiting,
            captchaSeen: turnSession.captchaSeenInSession,
            failure: turnSession.connectionFailure,
            bypassUnavailable: turnSession.bypassUnavailableReason,
            bypassNeededWhileOff: turnSession.bypassNeededWhileOff,
            runtimeBypassFailure: turnSession.runtimeBypassFailure
        )
    }

    var body: some View {
        ZStack {
            HomeBackgroundGradient(isConnected: isConnected)
                .ignoresSafeArea()

            stackedLayout
            .animation(connectionEffectsEnabled ? Animation.bouncy : nil, value: isConnected)
            .sensoryFeedback(trigger: isConnected) { _, _ in
                guard connectionEffectsEnabled else { return nil }
                return .impact
            }
        }
        .overlay(alignment: .bottom) { tabBarScrim }
        // The home screen is always the dark gradient.
        .colorScheme(.dark)
        .sheet(isPresented: $showingAddSheet) {
            DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                AddProxyView(showingManualAddSheet: $showingManualAddSheet)
                    .environment(operations)
            }
        }
        .sheet(isPresented: $showingManualAddSheet) {
            ProxyEditorView { configuration in
                operations.configurations.add(configuration)
                operations.selection.selectIfNone(configuration)
            }
        }
        .sheet(isPresented: $showingStatsSheet) {
            statsSheet
        }
        .alert("VPN Error", isPresented: Binding(
            get: { tunnel.startError != nil },
            set: { if !$0 { tunnel.startError = nil } }
        )) {
            Button("OK") { tunnel.startError = nil }
        } message: {
            Text(tunnel.startError ?? "")
        }
        .alert("Update Failed", isPresented: Binding(
            get: { subscriptionRefreshError != nil },
            set: { if !$0 { subscriptionRefreshError = nil } }
        )) {
            Button("OK", role: .cancel) { subscriptionRefreshError = nil }
        } message: {
            Text(subscriptionRefreshError ?? "")
        }
        .confirmationDialog(
            subscriptionPendingDeletion.map {
                String(
                    localized: "server.list.delete.confirm.title",
                    defaultValue: "Delete \u{201C}\($0.name)\u{201D}?",
                    comment: "Заголовок подтверждения удаления подписки"
                )
            } ?? "",
            isPresented: Binding(
                get: { subscriptionPendingDeletion != nil },
                set: { if !$0 { subscriptionPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: subscriptionPendingDeletion
        ) { subscription in
            Button("Delete", role: .destructive) {
                operations.subscriptions.delete(subscription)
                subscriptionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { subscriptionPendingDeletion = nil }
        } message: { _ in
            Text(String(
                localized: "server.list.delete.confirm.message",
                defaultValue: "Its servers will be removed from the list.",
                comment: "Пояснение к подтверждению удаления подписки"
            ))
        }
        // The sheet fires ahead of the next phase poll, so the latch lives here.
        .onChange(of: captchaMonitor.captchaWaiting) { _, waiting in
            if waiting { turnSession.noteCaptchaSeen() }
        }
        .onChange(of: tunnel.isManagerReady, initial: true) { _, ready in
            guard ready, !connectionEffectsEnabled else { return }
            Task { @MainActor in connectionEffectsEnabled = true }
        }
    }

    // MARK: - Layouts

    private var stackedLayout: some View {
        ScrollView {
            connectionControls
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.bottom, Self.scrollBottomInset)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }

    private var statsSheet: some View {
        NavigationStack {
            ScrollView {
                ConnectionStatsView()
                    .padding(20)
            }
            .navigationTitle(String(localized: "stats.sheet.title", defaultValue: "Statistics", comment: "Заголовок шита со статистикой подключения"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingStatsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Vertical rhythm per the «Иконка TURN» mockup: top bar, power button, status,
    /// stage row, server list.
    private var connectionControls: some View {
        VStack(spacing: 0) {
            topBar

            Spacer().frame(height: 8)

            VStack(spacing: 14) {
                powerButton
                statusLabel
            }
            .opacity(configStore.hasConfigurations ? 1 : 0.4)

            Spacer().frame(height: 14)

            // Without a subscription there is nowhere to connect, so no stages either.
            if configStore.hasConfigurations {
                ConnectionGraphSection(
                    stage: stage,
                    pool: turnSession.turnPool,
                    serverName: selection.selectedConfiguration?.name
                )
                Spacer().frame(height: 18)
            }

            serverList
        }
        .frame(maxWidth: Self.maxControlPaneWidth)
    }

    /// Adding a subscription lives up here because the list it would otherwise hang off
    /// does not exist when there is nothing yet. Right-aligned, as in the mockup.
    private var topBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Button {
                showingAddSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "server.list.addSubscription", defaultValue: "Add Subscription", comment: "Кнопка добавления подписки"))
        }
        .frame(height: 44)
        .padding(.trailing, -6)   // визуальный край круга совпадает с краем карточек
    }

    /// Fades the rows out under the tab bar instead of letting them cut off (SPEC.md §2).
    private var tabBarScrim: some View {
        let base: Color = isConnected ? .connectedBackgroundEnd : .disconnectedBackgroundEnd
        // Pinned to the physical bottom edge: the overlay itself ends at the safe area
        // (above the tab bar), so the band is stretched by that inset to keep its top
        // where it was and run all the way down under the tab bar.
        return GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    stops: [
                        .init(color: base.opacity(0), location: 0),
                        .init(color: base.opacity(0.88), location: 0.46),
                        .init(color: base, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 112 + proxy.safeAreaInsets.bottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var powerButton: some View {
        PowerButton(
            isConnected: isConnected,
            isTransitioning: isTransitioning,
            isLoading: isLoading,
            isDisabled: isPowerButtonDisabled,
            animatesChanges: connectionEffectsEnabled,
            isTurnForced: turnSession.turnForcedInSession
        ) {
            guard !isLoading, configStore.hasConfigurations else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                operations.tunnel.toggle()
            }
        } longPressAction: {
            guard !isLoading, configStore.hasConfigurations else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                operations.tunnel.connectForcingTurn()
            }
        }
    }

    /// Stable ids: a fresh `UUID()` per render would make SwiftUI treat the sections
    /// as new every time the list updates.
    private static let standaloneSectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let chainsSectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Standalone configurations, chains, then one section per subscription.
    private var pickerSections: [PickerSection] {
        var result: [PickerSection] = []
        let standalone = configStore.configurations
            .filter { $0.subscriptionId == nil }
            .map { PickerItem(id: $0.id, name: $0.name) }
        if !standalone.isEmpty {
            result.append(PickerSection(id: Self.standaloneSectionId, header: nil, items: standalone))
        }
        let chains = chainStore.chains.map { PickerItem(id: $0.id, name: $0.name) }
        if !chains.isEmpty {
            result.append(PickerSection(
                id: Self.chainsSectionId,
                header: String(localized: "Chains"),
                items: chains
            ))
        }
        result.append(contentsOf: subscriptionStore.pickerSections(configurationStore: configStore))
        return result
    }

    /// Chain latencies live in their own dictionary; the list keys everything by row id.
    private var listLatencies: [UUID: LatencyResult] {
        latency.latencyResults.merging(latency.chainLatencyResults) { current, _ in current }
    }

    private var isMeasuringLatencies: Bool {
        latency.latencyResults.values.contains(.testing)
            || latency.chainLatencyResults.values.contains(.testing)
    }

    /// A selected chain is resolved into a configuration with a brand new id, so the
    /// chain's own id is what the row matches on.
    private var selectedRowId: UUID? {
        selection.selectedChainId ?? selection.selectedConfiguration?.id
    }

    private func select(id: UUID) {
        if let chain = chainStore.chains.first(where: { $0.id == id }) {
            operations.selection.selectChain(chain, configurations: configStore.configurations)
        } else if let configuration = configStore.configurations.first(where: { $0.id == id }) {
            operations.selection.select(configuration)
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if !configStore.isLoaded {
            // Never the empty state: on launch that would flash "No subscription".
            loadingCard
        } else {
            ServerListSection(
                sections: pickerSections,
                selectedId: selectedRowId,
                latencies: listLatencies,
                isMeasuring: isMeasuringLatencies,
                onSelect: { select(id: $0) },
                onMeasure: {
                    operations.latency.testAll(configStore.configurations)
                    operations.latency.testChains(chainStore.chains)
                },
                onAddSubscription: { showingAddSheet = true },
                onDeleteSubscription: { id in
                    subscriptionPendingDeletion = subscriptionStore.subscriptions.first { $0.id == id }
                },
                onRefreshSubscription: { refreshSubscription(id: $0) },
                refreshingSubscription: refreshingSubscription,
                backupRouteMode: settings.turnMode
            )
        }
    }

    /// Same path as the Update action on the Proxies tab, which Pro Mode hides.
    private func refreshSubscription(id: UUID) {
        guard refreshingSubscription == nil,
              let subscription = subscriptionStore.subscriptions.first(where: { $0.id == id }) else { return }
        refreshingSubscription = id
        Task {
            do {
                try await operations.subscriptions.refresh(subscription)
            } catch {
                subscriptionRefreshError = error.localizedDescription
            }
            refreshingSubscription = nil
        }
    }

    private var loadingCard: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.primary.opacity(0.1))
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }
    
    /// Tapping the status opens the statistics sheet — the stats no longer live on
    /// the home screen itself.
    private var statusLabel: some View {
        Button {
            // Not `.disabled`: a disabled plain button dims its label, and the status
            // must stay white while disconnected.
            guard isConnected else { return }
            showingStatsSheet = true
        } label: {
            HStack(spacing: 5) {
                // A failed stage keeps the node red; the label goes back to the raw
                // tunnel status so it does not claim "Connecting" forever.
                Text(stage.isFailed ? tunnel.status.localizedText : stage.statusText)
                    .font(.system(size: 17, weight: .semibold))
                if isConnected {
                    Text(verbatim: "›")
                        .font(.system(size: 17, weight: .regular))
                        .opacity(stage.lacksBypass ? 0.8 : 0.55)
                }
            }
            // Connected, but without the backup route it needed: say so in red.
            .foregroundStyle(stage.lacksBypass ? TurnStatusPalette.warningText : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isConnected)
    }
}

// MARK: - Background

/// Our home gradient (mockup): blue when connected, graphite otherwise. Named
/// `HomeBackgroundGradient` to stay clear of upstream's theme-driven `BackgroundGradient`.
private struct HomeBackgroundGradient: View {
    let isConnected: Bool

    var body: some View {
        if isConnected {
            LinearGradient(colors: [.connectedBackgroundStart, .connectedBackgroundEnd], startPoint: .top, endPoint: .bottom)
                .transition(.blurReplace)
        } else {
            LinearGradient(colors: [.disconnectedBackgroundStart, .disconnectedBackgroundEnd], startPoint: .top, endPoint: .bottom)
                .transition(.blurReplace)
        }
    }
}

// MARK: - Power Button

private struct PowerButton: View {
    /// Mockup: 112 pt disc with an 8 pt translucent ring around it.
    private static let circleDiameter: CGFloat = 112
    private static let ringWidth: CGFloat = 8
    /// Holding the button this long connects through TURN whatever the TURN mode says.
    static let forceTurnHold: Double = 2

    let isConnected: Bool
    let isTransitioning: Bool
    let isLoading: Bool
    let isDisabled: Bool
    let animatesChanges: Bool
    /// The session was forced through TURN; the ring stays drawn as a reminder.
    let isTurnForced: Bool
    let action: () -> Void
    let longPressAction: () -> Void

    /// The finger is down on the button (drives the hold ring).
    @GestureState private var isHolding = false
    /// The hold completed; swallows the tap the button fires on release.
    @State private var didLongPress = false
    /// Bumped on each completed hold, for the haptic.
    @State private var holdCount = 0

    var body: some View {
        Button {
            if didLongPress {
                didLongPress = false
                return
            }
            action()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: Self.ringWidth)
                    .frame(width: Self.circleDiameter + Self.ringWidth, height: Self.circleDiameter + Self.ringWidth)
                Circle()
                    .fill(Color.white.opacity(isConnected ? 0.14 : 0.08))
                    .frame(width: Self.circleDiameter, height: Self.circleDiameter)
                holdRing
                if isTransitioning || isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(isConnected ? 1 : 0.75))
                }
            }
            .frame(width: Self.circleDiameter + 2 * Self.ringWidth, height: Self.circleDiameter + 2 * Self.ringWidth)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Self.forceTurnHold)
                .updating($isHolding) { pressing, state, _ in state = pressing }
                .onEnded { _ in
                    guard !isDisabled else { return }
                    didLongPress = true
                    holdCount += 1
                    longPressAction()
                }
        )
        .sensoryFeedback(.impact(weight: .heavy), trigger: holdCount)
        .animation(animatesChanges ? Animation.easeInOut(duration: 0.6) : nil, value: isConnected)
        .accessibilityHint(String(
            localized: "home.power.forceTurnHint",
            defaultValue: "Hold for two seconds to connect through TURN.",
            comment: "VoiceOver-подсказка кнопки питания про долгое нажатие"
        ))
        .accessibilityAction(named: String(
            localized: "home.power.forceTurnAction",
            defaultValue: "Connect through TURN",
            comment: "VoiceOver-действие кнопки питания: подключиться через TURN"
        )) {
            guard !isDisabled else { return }
            longPressAction()
        }
    }

    /// Fills over the hold; drawn full while the session is forced through TURN.
    private var holdRing: some View {
        Circle()
            .trim(from: 0, to: isHolding || isTurnForced ? 1 : 0)
            .stroke(Color.cyan.opacity(isTurnForced && !isHolding ? 0.55 : 0.9),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: Self.circleDiameter + Self.ringWidth, height: Self.circleDiameter + Self.ringWidth)
            .animation(isHolding ? .linear(duration: Self.forceTurnHold) : .easeOut(duration: 0.2), value: isHolding)
            .allowsHitTesting(false)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Disconnected") {
    let container = AppContainer.preview()
    return HomeView()
        .environment(AppSettings())
        .environment(Operations(container: container))
        .environment(container.tunnel)
        .environment(container.turnSession)
        .environment(container.selection)
        .environment(container.latency)
        .environment(container.configurationStore)
        .environment(container.chainStore)
        .environment(container.subscriptionStore)
        .environment(container.stats)
}
#endif
