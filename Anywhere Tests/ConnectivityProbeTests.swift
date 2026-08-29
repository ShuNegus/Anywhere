//
//  ConnectivityProbeTests.swift
//  Anywhere
//

import Testing
@testable import Anywhere

/// The auto-mode decision hinges on this table, so it is pinned here. The probes
/// themselves need a real network and are exercised on device.
struct ConnectivityProbeTests {

    @Test func openInternetWins() {
        #expect(ConnectivityProbe.verdict(homeReachable: true, openReachable: true) == .open)
        // The open host answering is enough on its own: a network where the domestic
        // hosts happen to fail still needs no bypass.
        #expect(ConnectivityProbe.verdict(homeReachable: false, openReachable: true) == .open)
    }

    @Test func domesticOnlyMeansCensored() {
        #expect(ConnectivityProbe.verdict(homeReachable: true, openReachable: false) == .blocked)
    }

    /// Nothing answered: no network rather than a censored one, so the VPN must not start.
    @Test func nothingReachableIsOffline() {
        #expect(ConnectivityProbe.verdict(homeReachable: false, openReachable: false) == .offline)
    }

    /// One flaky handshake must not be able to call an ordinary network censored, so the
    /// open side is probed against several independent hosts.
    @Test func severalOpenHostsAreProbed() {
        #expect(ConnectivityProbe.openHosts.count >= 3)
        #expect(Set(ConnectivityProbe.openHosts).count == ConnectivityProbe.openHosts.count)
        #expect(Set(ConnectivityProbe.openHosts).isDisjoint(with: Set(ConnectivityProbe.homeHosts)))
    }

    /// The user waits on the pre-flight, nobody waits on the background probe — so the
    /// background one buys accuracy with patience.
    @Test func backgroundProbeIsMorePatientThanPreflight() {
        #expect(ProbeProfile.preflight.timeout == .seconds(2))
        #expect(ProbeProfile.background.timeout == .seconds(5))
        #expect(ProbeProfile.background.timeout > ProbeProfile.preflight.timeout)
    }
}
