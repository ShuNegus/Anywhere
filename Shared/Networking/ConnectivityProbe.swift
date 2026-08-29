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

/// How much patience a probe gets.
///
/// The two callers want opposite things. The pre-flight runs with the user watching the
/// connect button, so it has to answer fast even at the cost of an occasional wrong
/// "unreachable". The in-tunnel auto pilot has nobody waiting, and a false `.blocked`
/// there is expensive — it moves every flow onto the relay — so it waits longer.
nonisolated enum ProbeProfile: Sendable {
    case preflight
    case background

    var timeout: Duration {
        switch self {
        case .preflight: .seconds(2)
        case .background: .seconds(5)
        }
    }
}

/// One host's outcome, kept so a decision can be logged with the evidence behind it.
nonisolated struct HostResult: Sendable {
    let host: String
    let reachable: Bool
    let elapsedMs: Int
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
    /// Hosts a censored network blocks. Several of them: one unlucky handshake against a
    /// single host used to be enough to call an ordinary Wi-Fi "censored".
    static let openHosts = ["google.com", "cloudflare.com", "gstatic.com"]

    private static let probePort: UInt16 = 443

    /// Runs all probes in parallel and returns the verdict. Never throws: any failure
    /// (timeout, reset, bad certificate) simply counts as "not reachable".
    static func classify(profile: ProbeProfile) async -> ConnectivityVerdict {
        await classifyDetailed(profile: profile).verdict
    }

    /// The verdict plus per-host evidence, in the order `openHosts + homeHosts`.
    static func classifyDetailed(profile: ProbeProfile) async -> (verdict: ConnectivityVerdict, results: [HostResult]) {
        // Probe handshakes must not pollute the live dial/handshake gauges.
        ConnectionMetrics.shared.suspendRecording()
        defer { ConnectionMetrics.shared.resumeRecording() }

        let timeout = profile.timeout
        var homeReachable = false
        var openReachable = false
        var byHost: [String: HostResult] = [:]

        await withTaskGroup(of: (isOpenHost: Bool, result: HostResult).self) { group in
            for host in openHosts {
                group.addTask { (true, await measure(host, timeout: timeout)) }
            }
            for host in homeHosts {
                group.addTask { (false, await measure(host, timeout: timeout)) }
            }
            for await outcome in group {
                byHost[outcome.result.host] = outcome.result
                guard outcome.result.reachable else { continue }
                // A single open host answering is enough: the others may be down, blocked
                // by the operator, or simply slow.
                if outcome.isOpenHost { openReachable = true } else { homeReachable = true }
            }
        }

        let results = (openHosts + homeHosts).compactMap { byHost[$0] }
        let verdict = verdict(homeReachable: homeReachable, openReachable: openReachable)
        logger.debug("[ConnectivityProbe] home=\(homeReachable) open=\(openReachable) → \(verdict.rawValue)")
        return (verdict, results)
    }

    /// Pure decision, split out so it can be tested without touching the network.
    static func verdict(homeReachable: Bool, openReachable: Bool) -> ConnectivityVerdict {
        if openReachable { return .open }
        if homeReachable { return .blocked }
        return .offline
    }

    /// One host: fresh DNS, then a full TLS handshake carrying that host as the SNI.
    static func reachable(_ host: String, timeout: Duration) async -> Bool {
        guard let address = await DNSResolver.shared.resolveHost(host, forceFresh: true) else {
            return false
        }
        let client = TLSClient(configuration: TLSConfiguration(serverName: host, alpn: ["http/1.1"]))
        do {
            let record = try await withDialDeadline(timeout) {
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

    /// `reachable`, timed. The clock is monotonic so a wall-clock adjustment mid-probe
    /// cannot produce a negative duration.
    private static func measure(_ host: String, timeout: Duration) async -> HostResult {
        let started = ContinuousClock.now
        let ok = await reachable(host, timeout: timeout)
        let elapsed = ContinuousClock.now - started
        let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return HostResult(host: host, reachable: ok, elapsedMs: millis)
    }
}
