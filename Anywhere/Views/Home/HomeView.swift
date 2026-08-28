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
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(SubscriptionStore.self) private var subscriptionStore
    
    private static let horizontalPadding: CGFloat = 20
    private static let maxControlPaneWidth: CGFloat = 500
    /// Clears the last row from under ``tabBarScrim`` (112 tall) when scrolled to the end.
    private static let scrollBottomInset: CGFloat = 96

    @State private var connectionEffectsEnabled = false

    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false
    @State private var showingStatsSheet = false

    @State private var captchaMonitor = TurnCaptchaMonitor.shared

    private var isLoading: Bool { !configStore.isLoaded }

    private var isConnected: Bool {
        viewModel.vpnStatus == .connected
    }

    private var isTransitioning: Bool { viewModel.vpnStatus.isTransitioning }

    private var turnOn: Bool { settings.turnFeatureEnabled && settings.turnMode != .off }

    /// Stage for the connection graph, driven by the phase the vk-turn core reports.
    /// The captcha monitor stays in as an independent signal: it fires the moment the
    /// sheet comes up, ahead of the next phase poll.
    private var stage: ConnectionStage {
        ConnectionStage.resolve(
            status: viewModel.status,
            turnEnabled: turnOn,
            turnPhase: viewModel.turnPhase,
            captchaPending: captchaMonitor.captchaWaiting,
            vpnProfileUp: viewModel.isManagerReady && viewModel.vpnStatus == .connecting
        )
    }

    var body: some View {
        ZStack {
            BackgroundGradient(isConnected: isConnected)
                .ignoresSafeArea()

            stackedLayout
            .animation(connectionEffectsEnabled ? Animation.bouncy : nil, value: isConnected)
            .sensoryFeedback(trigger: isConnected) { _, _ in
                guard connectionEffectsEnabled else { return nil }
                return .impact
            }
        }
        .overlay(alignment: .bottom) { tabBarScrim }
        .colorScheme(settings.homeColorScheme.colorSceme)
        .sheet(isPresented: $showingAddSheet) {
            DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                AddProxyView(showingManualAddSheet: $showingManualAddSheet)
            }
        }
        .sheet(isPresented: $showingManualAddSheet) {
            ProxyEditorView { configuration in
                configStore.add(configuration); viewModel.selectIfNone(configuration)
            }
        }
        .sheet(isPresented: $showingStatsSheet) {
            statsSheet
        }
        .alert("VPN Error", isPresented: Binding(
            get: { viewModel.startError != nil },
            set: { if !$0 { viewModel.startError = nil } }
        )) {
            Button("OK") { viewModel.startError = nil }
        } message: {
            Text(viewModel.startError ?? "")
        }
        .onChange(of: viewModel.isManagerReady, initial: true) { _, ready in
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

    private var connectionControls: some View {
        // 80 was the old gap; the graph does not fit the first screen with it.
        VStack(spacing: 32) {
            VStack(spacing: 20) {
                powerButton
                statusLabel
            }
            VStack(spacing: 20) {
                ConnectionGraphView(stage: stage)
                serverList
            }
        }
        .frame(maxWidth: Self.maxControlPaneWidth)
    }

    /// Fades the rows out under the tab bar instead of letting them cut off (SPEC.md §2).
    private var tabBarScrim: some View {
        let base = isConnected
            ? color(settings.connectedBackgroundEndData, default: .connectedBackgroundEnd)
            : color(settings.disconnectedBackgroundEndData, default: .disconnectedBackgroundEnd)
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base.opacity(0.88), location: 0.46),
                .init(color: base, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 112)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func color(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }

    private var powerButton: some View {
        PowerButton(
            isConnected: isConnected,
            isTransitioning: isTransitioning,
            isLoading: isLoading,
            isDisabled: isLoading
                || (viewModel.isButtonDisabled(hasConfigurations: configStore.hasConfigurations)
                    && configStore.hasConfigurations),
            animatesChanges: connectionEffectsEnabled
        ) {
            guard !isLoading else { return }
            if configStore.hasConfigurations {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    viewModel.toggleVPN()
                }
            } else {
                showingAddSheet = true
            }
        }
    }

    /// Stable ids: a fresh `UUID()` per render would make SwiftUI treat the sections
    /// as new every time the list updates.
    private static let standaloneSectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let chainsSectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// The same three sources the old `Menu` listed.
    private var pickerSections: [PickerSection] {
        var result: [PickerSection] = []
        if !configStore.standalonePickerItems.isEmpty {
            result.append(PickerSection(
                id: Self.standaloneSectionId,
                header: nil,
                items: configStore.standalonePickerItems
            ))
        }
        if !chainStore.pickerItems.isEmpty {
            result.append(PickerSection(
                id: Self.chainsSectionId,
                header: String(localized: "Chains"),
                items: chainStore.pickerItems
            ))
        }
        result.append(contentsOf: subscriptionStore.pickerSections)
        return result
    }

    /// Chain latencies live in their own dictionary; the list keys everything by row id.
    private var listLatencies: [UUID: LatencyResult] {
        viewModel.latencyResults.merging(viewModel.chainLatencyResults) { current, _ in current }
    }

    private var isMeasuringLatencies: Bool {
        viewModel.latencyResults.values.contains(.testing)
            || viewModel.chainLatencyResults.values.contains(.testing)
    }

    /// A selected chain is resolved into a configuration with a brand new id, so the
    /// chain's own id is what the row matches on.
    private var selectedRowId: UUID? {
        viewModel.selectedChainId ?? viewModel.selectedConfiguration?.id
    }

    private func select(id: UUID) {
        if let chain = chainStore.chains.first(where: { $0.id == id }) {
            viewModel.selectChain(chain, configurations: configStore.configurations)
        } else if let configuration = configStore.configurations.first(where: { $0.id == id }) {
            viewModel.selectedConfiguration = configuration
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if !configStore.isLoaded {
            loadingCard
        } else if !pickerSections.isEmpty {
            ServerListSection(
                sections: pickerSections,
                selectedId: selectedRowId,
                latencies: listLatencies,
                isMeasuring: isMeasuringLatencies,
                onSelect: { select(id: $0) },
                onMeasure: {
                    viewModel.testLatencies(for: configStore.configurations)
                    viewModel.testAllChainLatencies(
                        chains: chainStore.chains,
                        configurations: configStore.configurations
                    )
                }
            )
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
            showingStatsSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(stage.statusText)
                    .font(.headline)
                if isConnected {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
    }
}

// MARK: - Background

private struct BackgroundGradient: View {
    @Environment(AppSettings.self) private var settings

    let isConnected: Bool

    var body: some View {
        if isConnected {
            LinearGradient(
                colors: [
                    color(settings.connectedBackgroundStartData, default: .connectedBackgroundStart),
                    color(settings.connectedBackgroundEndData, default: .connectedBackgroundEnd),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .transition(.blurReplace)
        } else {
            LinearGradient(
                colors: [
                    color(settings.disconnectedBackgroundStartData, default: .disconnectedBackgroundStart),
                    color(settings.disconnectedBackgroundEndData, default: .disconnectedBackgroundEnd),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .transition(.blurReplace)
        }
    }

    private func color(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }
}

// MARK: - Power Button

private struct PowerButton: View {
    private static let circleDiameter: CGFloat = 140

    let isConnected: Bool
    let isTransitioning: Bool
    let isLoading: Bool
    let isDisabled: Bool
    let animatesChanges: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if #available(iOS 27.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.regular, in: .circle)
                } else if #available(iOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.clear, in: .circle)
                } else {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: Self.circleDiameter)
                        .shadow(color: isConnected ? .cyan.opacity(0.4) : .black.opacity(0.08), radius: isConnected ? 24 : 8)
                }
                if isTransitioning || isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .light))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(animatesChanges ? Animation.easeInOut(duration: 0.6) : nil, value: isConnected)
    }
}

private struct ProminentCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        } else if #available(iOS 26.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .padding(16)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(.white.opacity(0.2))
                )
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connected") {
    let settings = AppSettings.shared
    
    let viewModel = VPNViewModel()
    viewModel.selectedConfiguration = ProxyConfiguration(
        name: "🇺🇸 Los Angeles",
        serverAddress: "203.0.113.10",
        serverPort: 443,
        outbound: .socks5(username: nil, password: nil)
    )
    viewModel.vpnStatus = .connected

    return HomeView()
        .environment(settings)
        .environment(viewModel)
        .environment(ConfigurationStore.shared)
        .environment(ChainStore.shared)
        .environment(SubscriptionStore.shared)
        .environment(ConnectionStatsModel.previewSeeded())
        .colorScheme(.dark)
}
#endif
