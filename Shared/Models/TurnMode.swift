//
//  TurnMode.swift
//  Anywhere
//
//  Created by NodePassProject on 8/28/26.
//

import Foundation

/// How proxy flows pick between the direct path and the vk-turn tunnel.
///
/// `.auto` probes reachability before the tunnel comes up and keeps watching for
/// network changes, so a move into a censored network switches the route on the fly.
nonisolated enum TurnMode: String, CaseIterable, Sendable {
    case auto
    case on
    case off

    var title: String {
        switch self {
        case .auto: return String(localized: "turn.mode.auto", defaultValue: "Auto")
        case .on: return String(localized: "turn.mode.on", defaultValue: "Enabled")
        case .off: return String(localized: "turn.mode.off", defaultValue: "Disabled")
        }
    }
}
