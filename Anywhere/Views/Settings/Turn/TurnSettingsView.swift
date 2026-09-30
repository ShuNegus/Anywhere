//
//  TurnSettingsView.swift
//  Anywhere
//

import NetworkExtension
import SwiftUI

struct TurnSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var servers: [TurnServerInfo] = []
    @State private var subscriptionLink: String?
    @State private var stats = TurnStatsResponse()
    @State private var captchaMonitor = TurnCaptchaMonitor.shared
    @State private var pollTask: Task<Void, Never>?

    private var effectiveLink: String {
        let manual = settings.turnVKLink.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? (subscriptionLink ?? "") : manual
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(selection: $settings.turnMode) {
                    ForEach(TurnMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    SettingsItem.turn.label
                }
                if settings.turnMode == .auto, let autoStatus {
                    LabeledContent("Route", value: autoStatus)
                }
            } footer: {
                Text("Tunnels proxy traffic through a VK Calls relay before it reaches the server, so the connection looks like an ordinary call. Auto probes the network first and only tunnels when the direct path is blocked. Holding the power button for two seconds connects through TURN once, whatever the mode.")
            }

            vkLinkSection

            if settings.turnMode != .off {
                Section {
                    Stepper(value: $settings.turnPeers, in: TurnLimits.minPeers...TurnLimits.maxPeers) {
                        LabeledContent("Peers", value: "\(settings.turnPeers)")
                    }
                    Picker("Captcha", selection: $settings.turnCaptchaManual) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                } header: {
                    Text("Relay")
                } footer: {
                    Text("The relay serves up to \(TurnLimits.relayPeersPerAccount) peers per VK account. Only when it is full does the app sign in with one more account — which may ask for one more captcha.")
                }
            }

            if settings.turnMode != .off {
                statisticsSection
                captchaSection
            }

            serversSection
        }
        .navigationTitle("TURN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
            startPolling()
        }
        .onChange(of: settings.turnMode) { _, mode in
            // A captcha can strand the relay while the app is backgrounded, so ask for
            // notification permission at the moment TURN is switched on.
            guard mode != .off else { return }
            Task { await TurnNotifications.requestAuthorizationIfNeeded() }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// What auto mode has settled on, straight from the extension. `nil` while the VPN
    /// is down — there is no decision to report until the tunnel is up.
    private var autoStatus: String? {
        switch stats.autoDecision {
        case TurnAutoState.Decision.turn.rawValue:
            return String(localized: "turn.auto.status.turn", defaultValue: "Using TURN")
        case TurnAutoState.Decision.direct.rawValue:
            return String(localized: "turn.auto.status.direct", defaultValue: "Direct")
        case TurnAutoState.Decision.undecided.rawValue,
             TurnAutoState.Decision.offline.rawValue:
            return String(localized: "turn.auto.status.probing", defaultValue: "Checking\u{2026}")
        default:
            return nil
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var vkLinkSection: some View {
        @Bindable var settings = settings
        Section {
            TextField("https://vk.com/call/join/…", text: $settings.turnVKLink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        } header: {
            Text("VK Calls Link")
        } footer: {
            if settings.turnVKLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let subscriptionLink, !subscriptionLink.isEmpty {
                    Text("Using the link from your subscription: \(subscriptionLink)")
                } else {
                    Text("No link was delivered with your subscription. Paste one here — TURN stays inactive without it.")
                }
            } else {
                Text("This link overrides the one delivered with your subscription.")
            }
        }
    }

    @ViewBuilder
    private var serversSection: some View {
        if servers.isEmpty {
            Section("Servers") {
                ContentUnavailableView(
                    "No TURN Servers",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add or refresh a subscription that advertises TURN relays.")
                )
            }
        } else {
            Section {
                ForEach(servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.host)
                            Text(server.peerAddr)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: server.isUsable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(server.isUsable ? .green : .secondary)
                            .accessibilityLabel(server.isUsable ? Text("Supported") : Text("Unsupported"))
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Only servers your subscription marks as supported are tunnelled; the rest connect directly.")
            }
        }
    }

    @ViewBuilder
    private var statisticsSection: some View {
        Section {
            LabeledContent("Sessions", value: "\(stats.totalSessions)")
            LabeledContent("Open Streams", value: "\(stats.totalStreams)")
            ForEach(stats.hosts) { host in
                LabeledContent(host.host, value: "\(host.sessions) / \(host.streams)\(credentialSuffix(for: host))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            Text(stats.hosts.isEmpty
                 ? "Counts appear once the VPN is connected and a relay is in use."
                 : "Per relay: sessions / open streams, then VK accounts in use.")
        }
    }

    /// VK accounts (credential sets) carrying this relay's sessions, and a marker while
    /// one more is being signed in. Each further account can raise its own captcha.
    private func credentialSuffix(for host: TurnHostStatistics) -> String {
        guard let core = host.core else { return "" }
        let inUse = core.sets.filter { $0.state != "retired" }.count
        var suffix = inUse > 0 ? " · \(inUse)" : ""
        if core.fetch.state != .idle { suffix += "+" }
        return suffix
    }

    @ViewBuilder
    private var captchaSection: some View {
        Section {
            Button("Solve Captcha") {
                captchaMonitor.requestShow()
            }
        } footer: {
            Text("VK sometimes asks for a captcha before the relay will accept a call. The prompt opens on its own when one is waiting; use this to reopen it.")
        }
    }

    // MARK: - Data

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await pollStatistics()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollStatistics() async {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
              let session = managers.first?.connection as? NETunnelProviderSession,
              session.status == .connected,
              let request = try? JSONEncoder().encode(TunnelMessage.fetchTurnStats) else {
            stats = TurnStatsResponse()
            return
        }
        let response = await ProviderMessageConcurrencyBridge.send(request, over: session)
        guard !Task.isCancelled,
              let response,
              let decoded = try? JSONDecoder().decode(TurnStatsResponse.self, from: response) else {
            return
        }
        stats = decoded
    }

    private func reload() {
        servers = TurnMetadataStore.shared.allServers()
        subscriptionLink = TurnMetadataStore.shared.subscriptionVKLink()
    }
}
