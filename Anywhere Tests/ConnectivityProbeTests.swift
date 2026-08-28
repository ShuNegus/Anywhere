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
}
