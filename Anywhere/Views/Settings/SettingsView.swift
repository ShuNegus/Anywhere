//
//  SettingsView.swift
//  Anywhere
//
//  Created by NodePassProject on 2/21/26.
//

import SwiftUI
import WidgetKit

/// Our settings tab, as in build 355: the few switches a regular user needs. Everything
/// else upstream 2.6 offers (tunnel, purify, MITM, modules, trusted networks, data,
/// personalization, about) lives in the Pro tabs that Pro Mode adds.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Operations.self) private var operations
    @Environment(RoutingRuleSetStore.self) private var ruleSetStore

    var body: some View {
        Form {
            appSection
            routingSection
            backupRouteSection
            diagnosisSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var appSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.proModeEnabled) {
                SettingsItem.proMode.label
            }
        } header: {
            Text(String(localized: "settings.section.app", defaultValue: "App", comment: "Заголовок раздела настроек приложения"))
        } footer: {
            if settings.proModeEnabled {
                Text(String(
                    localized: "settings.proMode.footer",
                    defaultValue: "Dashboard, Proxies and Toolbox tabs are shown.",
                    comment: "Подпись под тумблером Pro Mode, когда он включён"
                ))
            }
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        Section("Routing") {
            Toggle(isOn: Binding(
                get: { settings.isGlobalMode },
                set: {
                    settings.isGlobalMode = $0
                    ControlCenter.shared.reloadControls(ofKind: "su.smd.Anywhere.Widget.VPNToggle")
                }
            )) {
                SettingsItem.globalMode.label
            }
            if !settings.isGlobalMode {
                if let adBlock = ruleSetStore.adBlockRuleSet {
                    Toggle(isOn: Binding(
                        get: { adBlock.assignedConfigurationId == "REJECT" },
                        set: { operations.routingRuleSets.updateAssignment(adBlock, configurationId: $0 ? "REJECT" : nil) }
                    )) {
                        SettingsItem.adBlocking.label
                    }
                }
                Picker(selection: Binding(
                    get: { ruleSetStore.bypassCountryCode },
                    set: { operations.routingRuleSets.setBypassCountryCode($0) }
                )) {
                    Text("Disable").tag("")
                    ForEach(CountryBypassCatalog.shared.supportedCountryCodes, id: \.self) { code in
                        Text(countryLabel(for: code)).tag(code)
                    }
                } label: {
                    SettingsItem.countryBypass.label
                }
            }
        }
    }

    @ViewBuilder
    private var backupRouteSection: some View {
        if settings.turnFeatureEnabled {
            Section("Utilities") {
                NavigationLink {
                    TurnSettingsView()
                } label: {
                    SettingsItem.turn.label
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosisSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                LogsView()
            } label: {
                SettingsItem.logs.label
            }
            NavigationLink {
                RequestsView()
            } label: {
                SettingsItem.requests.label
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                AcknowledgementsView()
            } label: {
                TextWithColorfulIcon(title: "Acknowledgements", comment: nil, systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
            }
        }
    }

    private func flag(for countryCode: String) -> String {
        String(countryCode.unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
        }.map(Character.init))
    }

    private func countryLabel(for code: String) -> String {
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        return "\(flag(for: code)) \(name)"
    }
}
