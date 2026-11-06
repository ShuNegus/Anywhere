//
//  AnywhereApp.swift
//  Anywhere
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI
import AppIntents

@main
struct AnywhereApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer
    @State private var operations: Operations
    @State private var settings: AppSettings
    @State private var voyagerStore = VoyagerStore()
    @State private var mitmCertificateController = MITMCertificateController()
    @State private var deepLinkManager = DeepLinkManager()

    init() {
        #if DEBUG
        // Simulator demo for screenshots: skip onboarding so the seeded home shows.
        if ProcessInfo.processInfo.arguments.contains(DebugBackupRouteSeed.launchArgument) {
            AWCore.setOnboardingCompleted(true)
        }
        #endif
        let container = AppContainer()
        container.start()
        let operations = Operations(container: container)

        let settings = AppSettings()
        #if DEBUG
        if let pro = DebugBackupRouteSeed.demoProMode { settings.proModeEnabled = pro }
        #endif
        settings.onTunnelBehaviorChange = { [weak tunnel = container.tunnel] in
            tunnel?.reconnect()
        }

        SubscriptionAutoRefresher.shared.configure(store: container.subscriptionStore) { subscription in
            try await operations.subscriptions.refresh(subscription)
        }

        AppDependencyManager.shared.add(dependency: container)
        AppDependencyManager.shared.add(dependency: operations)
        AppDependencyManager.shared.add(dependency: settings)

        Task { await CloudSync.shared.start { keys in await operations.reload(keys) } }

        _container = State(initialValue: container)
        _operations = State(initialValue: operations)
        _settings = State(initialValue: settings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppShortcutParametersSync())
                .dynamicTypeSize(...DynamicTypeSize.large)
                .environment(operations)
                .environment(container.appState)
                .environment(container.tunnel)
                .environment(container.turnSession)
                .environment(container.selection)
                .environment(container.latency)
                .environment(container.stats)
                .environment(container.configurationStore)
                .environment(container.chainStore)
                .environment(container.groupStore)
                .environment(container.subscriptionStore)
                .environment(container.routingRuleSetStore)
                .environment(container.mitmRuleSetStore)
                .environment(container.moduleStore)
                .environment(container.certificateStore)
                .environment(settings)
                .environment(voyagerStore)
                .environment(mitmCertificateController)
                .environment(deepLinkManager)
                // The scene can be created while the app is in the background, and
                // `onChange` only fires on transitions, so seed the flag once here.
                .task { AWCore.setAppInForeground(scenePhase == .active) }
        }
        .onChange(of: scenePhase) { _, newValue in
            AWCore.setAppInForeground(newValue == .active)
            switch newValue {
            case .active:
                // Launch lands here too: the first transition is into `.active`.
                Task { await SubscriptionAutoRefresher.shared.run(reason: "activation") }
            case .background:
                SubscriptionBackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}
