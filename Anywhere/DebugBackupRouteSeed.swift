//
//  DebugBackupRouteSeed.swift
//  Anywhere
//
//  DEBUG only: launched with `-seedBackupRouteDemo`, fills an empty install with three
//  made-up subscriptions so the backup-route icon can be looked at on a simulator —
//  available (partial coverage), no VK link, and none. Nothing here touches a server:
//  the hosts are `.invalid` and no push block is stored, so nothing is ever refreshed.
//

#if DEBUG
import Foundation

@MainActor
enum DebugBackupRouteSeed {
    static let launchArgument = "-seedBackupRouteDemo"

    /// `-demoStage <name>`: shows the home screen in that connection stage without a
    /// tunnel, for simulator screenshots. Names: connecting, direct, viaTurn,
    /// noVkLink, captchaFailed, serverNotCovered, failed.
    static let demoStage: ConnectionStage? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoStage"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "connecting":       return .whitelistCheck
        case "direct":           return .connectedDirect
        case "viaTurn":          return .connectedViaTurn(captchaSolved: true)
        case "noVkLink":         return .connectedWithoutTurn(.noVkLink)
        case "captchaFailed":    return .connectedWithoutTurn(.captchaFailed)
        case "serverNotCovered": return .connectedWithoutTurn(.serverNotCovered)
        case "failed":           return .failed(.turnTimeout)
        default:                 return nil
        }
    }()

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        AWCore.setOnboardingCompleted(true)
        guard SubscriptionStore.shared.subscriptions.isEmpty else { return }

        func configs(_ servers: [(String, String)]) -> [ProxyConfiguration] {
            servers.compactMap { name, host in
                try? ProxyConfiguration.parse(url: "vless://00000000-0000-0000-0000-000000000001@\(host):443?encryption=none&type=tcp#\(name)")
            }
        }
        func relay(_ hosts: [String], link: String?) -> TurnMetadata {
            TurnMetadata(
                version: 1, vkLink: link, vkLinkRequired: true,
                servers: Dictionary(uniqueKeysWithValues: hosts.map {
                    ($0, TurnServerInfo(host: $0, supported: true, peerAddr: "203.0.113.1:56000", wrapKeyHex: "00"))
                })
            )
        }

        let store = SubscriptionStore.shared
        let main = Subscription(name: "Demo VPN", url: "https://demo.invalid/a", lastUpdate: .now)
        let mainRelay = relay(["usa1.demo.invalid", "by.demo.invalid"], link: "https://demo.invalid/call/join/demo")
        store.add(main,
                  configurations: configs([("🇺🇸 USA 1", "usa1.demo.invalid"),
                                           ("🇳🇱 Netherlands 1", "nl1.demo.invalid"),
                                           ("🇧🇾 Belarus", "by.demo.invalid")]),
                  turn: mainRelay, turnOutcome: .loaded(mainRelay))

        let noLink = Subscription(name: "Резервная подписка", url: "https://demo.invalid/b", lastUpdate: .now)
        let noLinkRelay = relay(["jp.demo.invalid"], link: nil)
        store.add(noLink,
                  configurations: configs([("🇯🇵 Japan", "jp.demo.invalid")]),
                  turn: noLinkRelay, turnOutcome: .loaded(noLinkRelay))

        let plain = Subscription(name: "Без обхода", url: "https://demo.invalid/c", lastUpdate: .now)
        store.add(plain,
                  configurations: configs([("🇩🇪 Germany", "de.demo.invalid")]),
                  turnOutcome: .loaded(nil))
    }
}
#endif
