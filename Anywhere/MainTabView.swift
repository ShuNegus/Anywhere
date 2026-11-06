//
//  MainTabView.swift
//  Anywhere
//
//  Created by NodePassProject on 6/13/26.
//

import SwiftUI
import NetworkExtension

/// Root of the app for our build: our home screen and settings for everyone; upstream
/// 2.6's own pages (dashboard, proxies, toolbox with routing/MITM/modules/diagnosis…)
/// appear as extra tabs only with Pro Mode on. Deep links, rule-set and module imports
/// stay in `ContentView`, which wraps this.
struct MainTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunnelController.self) private var tunnel
    @Environment(Operations.self) private var operations
    @Environment(ConfigurationStore.self) private var configStore
    @State private var selectedTab: AppTab = {
        #if DEBUG
        if let tab = DebugBackupRouteSeed.demoTab, let value = AppTab(demoName: tab) { return value }
        #endif
        return .home
    }()
    @State private var captchaMonitor = TurnCaptchaMonitor.shared

    /// A waiting captcha blocks every TURN relay, so it is watched app-wide rather than
    /// only while the TURN settings screen is open.
    private var isCaptchaWatchActive: Bool {
        settings.turnFeatureEnabled && settings.turnMode != .off && tunnel.rawStatus == .connected
    }

    var body: some View {
        tabView
            .onAppear {
                captchaMonitor.setActive(isCaptchaWatchActive)
                // Messages from the service arrive as visible pushes, so ask once on
                // first launch rather than only when the captcha watch starts.
                Task { await TurnNotifications.requestAuthorizationIfNeeded() }
            }
            .onChange(of: isCaptchaWatchActive) { _, newValue in
                captchaMonitor.setActive(newValue)
                if newValue { Task { await TurnNotifications.requestAuthorizationIfNeeded() } }
            }
            .sheet(isPresented: Binding(
                get: { captchaMonitor.showCaptcha },
                set: { if !$0 { captchaMonitor.userDismissed() } }
            )) {
                TurnCaptchaSheet()
            }
            .onChange(of: settings.proModeEnabled) { _, enabled in
                if !enabled && selectedTab.isPro {
                    selectedTab = .home
                }
            }
            #if DEBUG
            .task(id: configStore.isLoaded) {
                guard configStore.isLoaded else { return }
                DebugBackupRouteSeed.runIfRequested(operations: operations)
            }
            #endif
    }

    @ViewBuilder
    private var tabView: some View {
        // Icon-only tabs, as in our 355 design (the floating capsule).
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.home) {
                NavigationStack {
                    HomeView()
                }
                .toolbarColorScheme(.dark, for: .tabBar)
            } label: {
                Image("anywhere")
                    .accessibilityLabel(Text("Home"))
            }

            if settings.proModeEnabled {
                Tab(value: AppTab.dashboard) {
                    DashboardView()
                } label: {
                    Image(systemName: Page.dashboard.symbol)
                        .accessibilityLabel(Text(Page.dashboard.name))
                }

                Tab(value: AppTab.proxies) {
                    ProxiesView()
                } label: {
                    Image(systemName: "network")
                        .accessibilityLabel(Text("Proxies"))
                }

                Tab(value: AppTab.toolbox) {
                    ToolboxView()
                } label: {
                    Image(systemName: Page.toolbox.symbol)
                        .accessibilityLabel(Text(Page.toolbox.name))
                }
            }

            Tab(value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(Text("Settings"))
            }
        }
    }
}

private enum AppTab: Hashable {
    case home, dashboard, proxies, toolbox, settings

    init?(demoName: String) {
        switch demoName {
        case "home": self = .home
        case "dashboard": self = .dashboard
        case "proxies": self = .proxies
        case "toolbox": self = .toolbox
        case "settings": self = .settings
        default: return nil
        }
    }

    var isPro: Bool {
        switch self {
        case .dashboard, .proxies, .toolbox: true
        case .home, .settings: false
        }
    }
}
