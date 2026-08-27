//
//  TurnDialerConfigTests.swift
//  Anywhere
//

import Testing
import Foundation
@testable import Anywhere

/// The pool-identity invariant behind "Speedtest drops after 3-4 seconds": the registry
/// rebuilds every dialer when the fingerprint changes, so nothing that moves with traffic
/// may appear in it. All values here are invented.
struct TurnPoolFingerprintTests {

    private static let vkLink = "https://example.invalid/call/join/AAAAAAAAAAAAAAAA"

    /// Memory headroom collapsing under load changes the session count for *new* pools,
    /// but must leave the fingerprint — and therefore the live pools — alone.
    @Test func memoryPressureDoesNotChangeFingerprint() {
        let requested = 10
        let roomy = TurnMemoryPolicy.peers(requested: requested, available: 64 << 20, capActive: false)
        let tight = TurnMemoryPolicy.peers(requested: requested, available: 8 << 20, capActive: false)
        // The cap really does bite, otherwise this test would prove nothing.
        #expect(roomy.peers == 10)
        #expect(tight.peers == TurnMemoryPolicy.lowMemoryPeerCap)

        let before = TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: requested, manualCaptcha: false)
        let after = TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: requested, manualCaptcha: false)
        #expect(before == after)
    }

    @Test func userPeerSettingChangesFingerprint() {
        let ten = TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: 10, manualCaptcha: false)
        let four = TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: 4, manualCaptcha: false)
        #expect(ten != four)
    }

    @Test func linkAndCaptchaModeChangeFingerprint() {
        let base = TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: 10, manualCaptcha: false)
        #expect(base != TurnPoolFingerprint.make(vkLink: "https://example.invalid/call/join/BBBBBBBBBBBBBBBB", peers: 10, manualCaptcha: false))
        #expect(base != TurnPoolFingerprint.make(vkLink: Self.vkLink, peers: 10, manualCaptcha: true))
    }
}

struct TurnMemoryPolicyTests {

    @Test func goLimitIsClampedToTheExtensionBudget() {
        #expect(TurnMemoryPolicy.goLimit(available: 25 << 20) == 16 << 20)   // floor
        #expect(TurnMemoryPolicy.goLimit(available: 35 << 20) == 21 << 20)   // 60%
        #expect(TurnMemoryPolicy.goLimit(available: 60 << 20) == 28 << 20)   // ceiling
        #expect(TurnMemoryPolicy.goLimit(available: 4 << 20) == TurnMemoryPolicy.minimumGoLimit)
    }

    /// The cap engages below the low threshold and only lifts once headroom has clearly
    /// recovered, so a pool built while memory hovers at the line does not flap.
    @Test func peerCapHasHysteresis() {
        var state = TurnMemoryPolicy.peers(requested: 10, available: 40 << 20, capActive: false)
        #expect(state.peers == 10 && !state.capActive)

        state = TurnMemoryPolicy.peers(requested: 10, available: 12 << 20, capActive: state.capActive)
        #expect(state.peers == 4 && state.capActive)

        // Between the two thresholds: still capped.
        state = TurnMemoryPolicy.peers(requested: 10, available: 24 << 20, capActive: state.capActive)
        #expect(state.peers == 4 && state.capActive)

        state = TurnMemoryPolicy.peers(requested: 10, available: 40 << 20, capActive: state.capActive)
        #expect(state.peers == 10 && !state.capActive)
    }

    /// Outside an app extension the budget is unknown; take the user's setting as-is.
    @Test func unknownBudgetLeavesTheRequestAlone() {
        let state = TurnMemoryPolicy.peers(requested: 10, available: 0, capActive: false)
        #expect(state.peers == 10)
    }

    @Test func requestBelowTheCapIsNeverRaised() {
        let state = TurnMemoryPolicy.peers(requested: 2, available: 8 << 20, capActive: false)
        #expect(state.peers == 2)
    }
}
