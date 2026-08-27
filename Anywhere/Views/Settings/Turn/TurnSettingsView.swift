//
//  TurnSettingsView.swift
//  Anywhere
//

import SwiftUI

struct TurnSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var servers: [TurnServerInfo] = []
    @State private var subscriptionLink: String?

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

            serversSection
        }
        .navigationTitle("TURN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
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

    // MARK: - Data

    private func reload() {
        servers = TurnMetadataStore.shared.allServers()
        subscriptionLink = TurnMetadataStore.shared.subscriptionVKLink()
    }
}
