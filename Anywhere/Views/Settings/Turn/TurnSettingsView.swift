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
                Toggle(isOn: $settings.turnEnabled) {
                    SettingsItem.turn.label
                }
            } footer: {
                Text("Tunnels proxy traffic through a VK Calls relay before it reaches the server, so the connection looks like an ordinary call.")
            }

            vkLinkSection

            if settings.turnEnabled {
                Section("Relay") {
                    Stepper(value: $settings.turnPeers, in: TurnLimits.minPeers...TurnLimits.maxPeers) {
                        LabeledContent("Peers", value: "\(settings.turnPeers)")
                    }
                    Picker("Captcha", selection: $settings.turnCaptchaManual) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                }
            }

            if settings.turnEnabled {
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
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
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
                LabeledContent(host.host, value: "\(host.sessions) / \(host.streams)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            Text(stats.hosts.isEmpty
                 ? "Counts appear once the VPN is connected and a relay is in use."
                 : "Per relay: sessions / open streams.")
        }
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
