//
//  TurnAvailabilityTests.swift
//  Anywhere
//

import Foundation
import Testing
@testable import Anywhere

/// Backup route (TURN) status: what the `/turn` answer means for the subscription icon,
/// why a server cannot use the route, and how the connection graph shows it.
struct TurnAvailabilityTests {

    private static let metadataJSON = """
    {"turn": {"version": 1, "vk_link_required": true, "vk_link": "https://example.invalid/call/join/AAAA",
      "servers": {"alpha.example.invalid": {"peer_addr": "203.0.113.10:56000", "supported": true,
        "wrap_key_hex": "00112233445566778899aabbccddeeff"}}},
     "push": {"rev": 2, "rev_url": "https://example.invalid/x/rev", "apns_register_url": "https://example.invalid/x/push/apns"}}
    """

    private func metadata(vkLink: String? = "https://example.invalid/call/join/AAAA",
                          required: Bool? = true,
                          hosts: [String] = ["alpha.example.invalid"]) -> TurnMetadata {
        TurnMetadata(
            version: 1, vkLink: vkLink, vkLinkRequired: required,
            servers: Dictionary(uniqueKeysWithValues: hosts.map {
                ($0, TurnServerInfo(host: $0, supported: true, peerAddr: "203.0.113.10:56000", wrapKeyHex: "00"))
            })
        )
    }

    // MARK: - Classifying the /turn answer

    @Test func okWithTurnBlockIsLoaded() {
        let (outcome, push) = SubscriptionFetcher.outcome(data: Data(Self.metadataJSON.utf8), status: 200)
        guard case .loaded(let turn?) = outcome else { Issue.record("expected loaded metadata"); return }
        #expect(turn.servers.count == 1)
        #expect(push?.rev == 2)
    }

    @Test func okWithoutTurnBlockMeansNoBackupRoute() {
        let (outcome, push) = SubscriptionFetcher.outcome(data: Data(#"{"push": {"rev": 1, "rev_url": "https://e.invalid/r", "apns_register_url": "https://e.invalid/a"}}"#.utf8), status: 200)
        #expect(outcome == .loaded(nil))
        #expect(push != nil)
    }

    @Test func jsonNotFoundIsSubscriptionNotFound() {
        let (outcome, _) = SubscriptionFetcher.outcome(data: Data(#"{"error": "not found"}"#.utf8), status: 404)
        #expect(outcome == .notFound)
    }

    /// A third-party subscription host knows nothing of `/turn` and answers with a page.
    @Test func htmlNotFoundMeansNoBackupRoute() {
        let (outcome, _) = SubscriptionFetcher.outcome(data: Data("<html>404</html>".utf8), status: 404)
        #expect(outcome == .loaded(nil))
    }

    @Test func serverErrorIsAFailure() {
        #expect(SubscriptionFetcher.outcome(data: Data("{}".utf8), status: 503).0 == .failed)
        #expect(SubscriptionFetcher.outcome(data: Data(#"{"error": "x"}"#.utf8), status: 400).0 == .failed)
    }

    // MARK: - Subscription icon

    @Test func loadedMetadataIsAvailable() {
        let result = TurnAvailabilityPolicy.resolve(outcome: .loaded(metadata()), previous: nil, hasManualVKLink: false)
        #expect(result.availability == .available)
        #expect(result.store == .set(metadata()))
    }

    @Test func noTurnBlockIsNoneAndClearsMetadata() {
        let result = TurnAvailabilityPolicy.resolve(outcome: .loaded(nil), previous: metadata(), hasManualVKLink: false)
        #expect(result.availability == .absent)
        #expect(result.store == .set(nil))
    }

    @Test func missingRequiredLinkIsNoVkLink() {
        let empty = metadata(vkLink: "  ")
        #expect(TurnAvailabilityPolicy.resolve(outcome: .loaded(empty), previous: nil, hasManualVKLink: false).availability
                == .error(.noVkLink))
        // A link typed in by hand covers it; an optional link is not missing.
        #expect(TurnAvailabilityPolicy.resolve(outcome: .loaded(empty), previous: nil, hasManualVKLink: true).availability
                == .available)
        #expect(TurnAvailabilityPolicy.availability(of: metadata(vkLink: nil, required: false), hasManualVKLink: false)
                == .available)
    }

    @Test func notFoundKeepsMetadataButIsRed() {
        let result = TurnAvailabilityPolicy.resolve(outcome: .notFound, previous: metadata(), hasManualVKLink: false)
        #expect(result.availability == .error(.subscriptionNotFound))
        #expect(result.store == .keep)
    }

    /// A failed fetch never throws away settings that worked.
    @Test func failedFetchFallsBackToSavedMetadata() {
        let withSaved = TurnAvailabilityPolicy.resolve(outcome: .failed, previous: metadata(), hasManualVKLink: false)
        #expect(withSaved.availability == .available)
        #expect(withSaved.store == .keep)
        let withoutSaved = TurnAvailabilityPolicy.resolve(outcome: .failed, previous: nil, hasManualVKLink: false)
        #expect(withoutSaved.availability == .error(.loadFailed))
    }

    @Test func onlySubscriptionWideReasonsAreRedOnTheIcon() {
        #expect(TurnUnavailableReason.serverNotCovered.isAlarming == false)
        #expect(TurnUnavailableReason.allCases.filter(\.marksSubscription)
                == [.loadFailed, .subscriptionNotFound, .noVkLink, .linkRejected])
    }

    // MARK: - Why the selected server cannot use the route

    private func reason(mode: TurnMode? = .auto, forced: Bool = false,
                        availability: TurnAvailability? = .available,
                        metadata: TurnMetadata? = nil, host: String = "alpha.example.invalid",
                        hasVKLink: Bool = true) -> TurnUnavailableReason? {
        TurnAvailabilityPolicy.connectionReason(
            mode: mode, forced: forced, availability: availability,
            metadata: metadata ?? self.metadata(), serverHost: host, hasVKLink: hasVKLink)
    }

    @Test func coveredServerHasNoReason() {
        #expect(reason() == nil)
    }

    @Test func offModeSaysTurnedOff() {
        #expect(reason(mode: .off) == .disabledInSettings)
        // Holding the power button overrides the setting.
        #expect(reason(mode: .off, forced: true) == nil)
    }

    @Test func featureHiddenHasNoReason() {
        #expect(reason(mode: nil) == nil)
    }

    @Test func subscriptionErrorWins() {
        #expect(reason(availability: .error(.subscriptionNotFound)) == .subscriptionNotFound)
    }

    @Test func serverOutsideTheListIsNotCovered() {
        #expect(reason(host: "beta.example.invalid") == .serverNotCovered)
    }

    @Test func noLinkAnywhereIsNoVkLink() {
        #expect(reason(hasVKLink: false) == .noVkLink)
    }

    /// A subscription without a backup route connected directly before; only an explicit
    /// demand for the route turns that into a reason.
    @Test func subscriptionWithoutRouteAlarmsOnlyWhenDemanded() {
        #expect(reason(availability: .absent) == nil)
        #expect(reason(mode: .on, availability: .absent) == .serverNotCovered)
        #expect(reason(forced: true, availability: .absent) == .serverNotCovered)
    }

    @Test func runtimeReasonFollowsTheStep() {
        #expect(TurnAvailabilityPolicy.runtimeReason(inCaptcha: true) == .captchaFailed)
        #expect(TurnAvailabilityPolicy.runtimeReason(inCaptcha: false) == .runtimeFailed)
    }

    @Test func serversAreMarkedOnlyWhenCoverageIsPartial() {
        let partial = metadata(hosts: ["a.invalid"])
        #expect(TurnAvailabilityPolicy.marksServers(hosts: ["a.invalid", "b.invalid"], metadata: partial) == ["a.invalid"])
        let full = metadata(hosts: ["a.invalid", "b.invalid"])
        #expect(TurnAvailabilityPolicy.marksServers(hosts: ["a.invalid", "b.invalid"], metadata: full).isEmpty)
        #expect(TurnAvailabilityPolicy.marksServers(hosts: ["a.invalid"], metadata: nil).isEmpty)
    }

    // MARK: - Connection stage

    private func stage(turnMode: TurnMode? = .auto, autoDecision: TurnAutoState.Decision? = .turn,
                       bypassUnavailable: TurnUnavailableReason? = nil,
                       neededWhileOff: Bool = false,
                       runtime: TurnUnavailableReason? = nil) -> ConnectionStage {
        ConnectionStage.resolve(
            status: .connected, isPreflighting: false, turnMode: turnMode,
            autoDecision: autoDecision, turnPhase: nil, captchaPending: false,
            captchaSeen: false, failure: nil,
            bypassUnavailable: bypassUnavailable, bypassNeededWhileOff: neededWhileOff,
            runtimeBypassFailure: runtime)
    }

    @Test func neededButUnavailableConnectsWithoutBypass() {
        let resolved = stage(bypassUnavailable: .noVkLink)
        #expect(resolved == .connectedWithoutTurn(.noVkLink))
        #expect(resolved.isConnected)
        #expect(resolved.lacksBypass)
        #expect(resolved.statusText != VPNStatus.connected.localizedText)
    }

    @Test func unavailableButNotNeededIsPlainDirect() {
        #expect(stage(autoDecision: .direct, bypassUnavailable: .noVkLink) == .connectedDirect)
    }

    @Test func offModeAlarmsOnlyWhenTheProbeSaidBlocked() {
        #expect(stage(turnMode: .off, autoDecision: nil, bypassUnavailable: .disabledInSettings) == .connectedDirect)
        #expect(stage(turnMode: .off, autoDecision: nil, bypassUnavailable: .disabledInSettings, neededWhileOff: true)
                == .connectedWithoutTurn(.disabledInSettings))
    }

    @Test func runtimeFailureOverridesThePhase() {
        #expect(stage(runtime: .captchaFailed) == .connectedWithoutTurn(.captchaFailed))
    }

    @Test func graphMarksTheBrokenStep() {
        let noLink = ConnectionStage.connectedWithoutTurn(.noVkLink)
        #expect(noLink.state(of: .whitelistCheck) == .failed)
        #expect(noLink.state(of: .turnTunnel) == .failed)
        #expect(noLink.state(of: .connected) == .off)
        #expect(noLink.isEdgeTraversed(from: .vpnConnect, to: .whitelistCheck))
        #expect(!noLink.isEdgeTraversed(from: .whitelistCheck, to: .connected))

        let captcha = ConnectionStage.connectedWithoutTurn(.captchaFailed)
        #expect(captcha.state(of: .turnTunnel) == .done)
        #expect(captcha.state(of: .captcha) == .failed)

        // Not a breakage: the bypass node stays hollow.
        let notCovered = ConnectionStage.connectedWithoutTurn(.serverNotCovered)
        #expect(notCovered.state(of: .turnTunnel) == .off)
    }
}
