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

    /// Seeds the demo through the same operation a real subscription add goes through,
    /// so the stored TURN outcome drives the icon exactly as in the field.
    /// `-demoProMode YES|NO` and `-demoTab <home|dashboard|proxies|toolbox|settings>`:
    /// for screenshots of the settings and Pro tabs without tapping.
    static var demoProMode: Bool? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoProMode"), i + 1 < args.count else { return nil }
        return args[i + 1] == "YES"
    }

    static var demoTab: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoTab"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func runIfRequested(operations: Operations) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        AWCore.setOnboardingCompleted(true)
        guard operations.subscriptions.store.subscriptions.isEmpty else { return }

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
        func add(_ name: String, _ url: String, _ servers: [(String, String)], turn: TurnMetadata?) {
            let subscription = Subscription(name: name, url: url, lastUpdate: .now)
            let result = SubscriptionFetcher.Result(
                configurations: configs(servers), stableKeys: [:], name: nil,
                upload: nil, download: nil, total: nil, expire: nil,
                turn: turn, push: nil, turnOutcome: .loaded(turn),
                iconLight: nil, iconDark: nil
            )
            operations.subscriptions.add(subscription, result: result)
        }

        add("Demo VPN", "https://demo.invalid/a",
            [("🇺🇸 USA 1", "usa1.demo.invalid"), ("🇳🇱 Netherlands 1", "nl1.demo.invalid"), ("🇧🇾 Belarus", "by.demo.invalid")],
            turn: relay(["usa1.demo.invalid", "by.demo.invalid"], link: "https://demo.invalid/call/join/demo"))
        add("Резервная подписка", "https://demo.invalid/b",
            [("🇯🇵 Japan", "jp.demo.invalid")],
            turn: relay(["jp.demo.invalid"], link: nil))
        add("Без обхода", "https://demo.invalid/c",
            [("🇩🇪 Germany", "de.demo.invalid")],
            turn: nil)
    }
}
#endif
