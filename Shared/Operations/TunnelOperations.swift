//
//  TunnelOperations.swift
//  Anywhere
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation
import NetworkExtension

@MainActor
struct TunnelOperations {
    let tunnel: TunnelController
    let selection: ProxySelection
    /// Our backup route (TURN) layer: preflight, forced flag and watchdog wrap the
    /// tunnel's own connect/disconnect.
    let turnSession: TurnSessionModel

    func toggle() {
        switch tunnel.rawStatus {
        case .connected, .connecting:
            disconnect()
        case .disconnected, .invalid:
            connect()
        default:
            break
        }
    }

    func connect() {
        guard selection.selectedConfiguration != nil else { return }
        turnSession.connect()
    }

    /// The power button held for two seconds: connect (or reconnect) through TURN.
    func connectForcingTurn() {
        turnSession.connectForcingTurn()
    }

    func disconnect() {
        turnSession.noteUserDisconnect()
        tunnel.disconnect()
    }

    func reconnect() {
        turnSession.noteUserReconnect()
        tunnel.reconnect()
    }
}
