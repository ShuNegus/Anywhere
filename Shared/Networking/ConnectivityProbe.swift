//
//  ConnectivityProbe.swift
//  Anywhere
//
//  Created by NodePassProject on 8/28/26.
//

import Foundation

nonisolated private let logger = AnywhereLogger(category: "ConnectivityProbe")

/// What the direct path can currently reach.
nonisolated enum ConnectivityVerdict: String, Sendable {
    /// Nothing answered — the device has no usable network at all.
    case offline
    /// Domestic hosts answer, the open internet does not: censored network.
    case blocked
    /// The open internet answers; no bypass needed.
    case open
}

/// Classifies the current network by attempting real TLS handshakes.
///
/// A TCP connect is not enough: censoring middleboxes let the SYN/SYN-ACK through and
/// only kill the flow after seeing the SNI in the ClientHello, so a connect-only probe
/// reports "reachable" precisely in the networks that need the bypass. Every probe here
/// therefore runs a full handshake with the real server name.
nonisolated enum ConnectivityProbe {

    /// Hosts that stay reachable inside a censored network.
    static let homeHosts = ["vk.ru", "ya.ru"]
    /// A host that a censored network blocks.
    static let openHost = "google.com"

    static let probeTimeout: Duration = .seconds(2)
    private static let probePort: UInt16 = 443

    /// Runs all probes in parallel and returns the verdict. Never throws: any failure
    /// (timeout, reset, bad certificate) simply counts as "not reachable".
    static func classify() async -> ConnectivityVerdict {
        // Probe handshakes must not pollute the live dial/handshake gauges.
        ConnectionMetrics.shared.suspendRecording()
        defer { ConnectionMetrics.shared.resumeRecording() }

        var homeReachable = false
        var openReachable = false

        await withTaskGroup(of: (isOpenHost: Bool, reachable: Bool).self) { group in
            group.addTask { (true, await reachable(openHost)) }
            for host in homeHosts {
                group.addTask { (false, await reachable(host)) }
            }
            for await result in group {
                if result.isOpenHost {
                    openReachable = result.reachable
                } else if result.reachable {
                    homeReachable = true
                }
            }
        }

        let verdict = verdict(homeReachable: homeReachable, openReachable: openReachable)
        logger.debug("[ConnectivityProbe] home=\(homeReachable) open=\(openReachable) → \(verdict.rawValue)")
        return verdict
    }

    /// Pure decision, split out so it can be tested without touching the network.
    static func verdict(homeReachable: Bool, openReachable: Bool) -> ConnectivityVerdict {
        if openReachable { return .open }
        if homeReachable { return .blocked }
        return .offline
    }

    /// One host: fresh DNS, then a full TLS handshake carrying that host as the SNI.
    static func reachable(_ host: String) async -> Bool {
        guard let address = await DNSResolver.shared.resolveHost(host, forceFresh: true) else {
            return false
        }
        let client = TLSClient(configuration: TLSConfiguration(serverName: host, alpn: ["http/1.1"]))
        do {
            let record = try await withDialDeadline(probeTimeout) {
                client.cancel()
            } error: {
                AnywhereError.transport(.timedOut(.connect, endpoint: "\(host) (\(address))", detail: "reachability probe"))
            } discardingLateResult: { (record: TLSRecordConnection) in
                record.cancel()
            } operation: {
                try await client.connect(host: address, port: probePort)
            }
            record.cancel()
            return true
        } catch {
            client.cancel()
            return false
        }
    }
}
