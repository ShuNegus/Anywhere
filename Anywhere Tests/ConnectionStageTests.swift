//
//  ConnectionStageTests.swift
//  Anywhere
//

import Testing
@testable import Anywhere

/// The graph is only as honest as this resolver, and the signals feeding it come from
/// three different places (the tunnel status, the auto-mode probe and the Go core's
/// phase), so the whole table is pinned here.
struct ConnectionStageTests {

    private func resolve(
        status: VPNStatus = .connected,
        isPreflighting: Bool = false,
        turnMode: TurnMode? = .auto,
        autoDecision: TurnAutoState.Decision? = nil,
        turnPhase: TurnPhase? = nil,
        captchaPending: Bool = false,
        captchaSeen: Bool = false,
        failure: ConnectionFailure? = nil
    ) -> ConnectionStage {
        ConnectionStage.resolve(
            status: status,
            isPreflighting: isPreflighting,
            turnMode: turnMode,
            autoDecision: autoDecision,
            turnPhase: turnPhase,
            captchaPending: captchaPending,
            captchaSeen: captchaSeen,
            failure: failure
        )
    }

    // MARK: - Trunk

    @Test func idleWhenTheTunnelIsDown() {
        #expect(resolve(status: .disconnected) == .idle)
        #expect(resolve(status: .disconnecting) == .idle)
        #expect(resolve(status: .invalid) == .idle)
    }

    /// The pre-flight runs before the tunnel starts, so the status is still `.disconnected`.
    @Test func preflightIsTheNetworkCheck() {
        #expect(resolve(status: .disconnected, isPreflighting: true) == .networkCheck)
    }

    @Test func connectingIsTheVPNNode() {
        #expect(resolve(status: .connecting) == .vpnConnect)
        #expect(resolve(status: .reasserting) == .vpnConnect)
    }

    // MARK: - Auto mode

    /// The extension returns `startTunnel` early, so nodes 3-5 are walked while the
    /// system already reports `.connected`.
    @Test func undecidedProbeSitsOnTheWhitelistCheck() {
        #expect(resolve(autoDecision: .undecided) == .whitelistCheck)
        #expect(resolve(autoDecision: nil) == .whitelistCheck)
    }

    @Test func directVerdictSkipsTheBranch() {
        #expect(resolve(autoDecision: .direct) == .connectedDirect)
    }

    @Test func turnVerdictWalksTheBranch() {
        #expect(resolve(autoDecision: .turn, turnPhase: nil) == .turnTunnel)
        #expect(resolve(autoDecision: .turn, turnPhase: .vkAccess) == .turnTunnel)
        #expect(resolve(autoDecision: .turn, turnPhase: .tunnelSetup) == .turnTunnel)
        #expect(resolve(autoDecision: .turn, turnPhase: .captchaWait) == .captcha)
        #expect(resolve(autoDecision: .turn, turnPhase: .captchaAuto) == .captcha)
    }

    /// The sheet comes up ahead of the next phase poll, so the monitor wins on its own.
    @Test func aPendingCaptchaOutranksThePhase() {
        #expect(resolve(autoDecision: .turn, turnPhase: .tunnelSetup, captchaPending: true) == .captcha)
    }

    @Test func readyIsConnectedViaTurn() {
        #expect(resolve(autoDecision: .turn, turnPhase: .ready, captchaSeen: true)
                == .connectedViaTurn(captchaSolved: true))
        #expect(resolve(autoDecision: .turn, turnPhase: .ready, captchaSeen: false)
                == .connectedViaTurn(captchaSolved: false))
    }

    /// The captcha never came up: the route went through the node, the step did not run.
    @Test func anUnusedCaptchaNodeIsSkipped() {
        let stage = ConnectionStage.connectedViaTurn(captchaSolved: false)
        #expect(stage.state(of: .captcha) == .skipped)
        #expect(stage.state(of: .turnTunnel) == .done)
        #expect(ConnectionStage.connectedViaTurn(captchaSolved: true).state(of: .captcha) == .done)
    }

    // MARK: - Pinned modes

    /// `.on` and `.off` do not probe: the setting alone picks the route.
    @Test func pinnedModesIgnoreTheProbe() {
        #expect(resolve(turnMode: .on, autoDecision: nil, turnPhase: nil) == .turnTunnel)
        #expect(resolve(turnMode: .off, autoDecision: nil) == .connectedDirect)
        // The bypass feature switched off entirely.
        #expect(resolve(turnMode: nil, autoDecision: nil) == .connectedDirect)
    }

    // MARK: - Failures

    /// The tunnel stands but nothing is reachable behind it — not "connected".
    @Test func offlineWhileConnectedIsAFailure() {
        #expect(resolve(autoDecision: .offline) == .failed(.networkLost))
        // Not connected yet: the offline verdict alone does not fail the graph.
        #expect(resolve(status: .connecting, autoDecision: .offline) == .vpnConnect)
    }

    @Test func aRecordedFailureOutranksTheStatus() {
        #expect(resolve(status: .connected, autoDecision: .direct, failure: .turnTimeout)
                == .failed(.turnTimeout))
        #expect(resolve(status: .disconnected, failure: .vpnStartFailed) == .failed(.vpnStartFailed))
    }

    @Test func theFailedNodeIsTheOneThatStalled() {
        let stage = ConnectionStage.failed(.turnTimeout)
        #expect(stage.currentNode == .turnTunnel)
        #expect(stage.state(of: .turnTunnel) == .failed)
        #expect(stage.state(of: .vpnConnect) == .done)
        #expect(stage.state(of: .connected) == .off)
        #expect(!stage.isBusy && !stage.isConnected && stage.isFailed)
        // Every failure has something to say in the alert.
        for failure in ConnectionFailure.allCases {
            #expect(!failure.message.isEmpty)
        }
    }

    // MARK: - Edges

    /// The direct trunk greens only when the bypass was not needed; the branch edges
    /// green around a skipped captcha.
    @Test func trunkAndBranchEdges() {
        #expect(ConnectionStage.connectedDirect.isEdgeTraversed(from: .whitelistCheck, to: .connected))
        #expect(!ConnectionStage.connectedViaTurn(captchaSolved: true)
            .isEdgeTraversed(from: .whitelistCheck, to: .connected))
        #expect(!ConnectionStage.turnTunnel.isEdgeTraversed(from: .whitelistCheck, to: .connected))

        let viaTurn = ConnectionStage.connectedViaTurn(captchaSolved: false)
        #expect(viaTurn.isEdgeTraversed(from: .whitelistCheck, to: .turnTunnel))
        #expect(viaTurn.isEdgeTraversed(from: .turnTunnel, to: .captcha))
        #expect(viaTurn.isEdgeTraversed(from: .captcha, to: .connected))

        // Direct route leaves the branch grey on both sides.
        #expect(!ConnectionStage.connectedDirect.isEdgeTraversed(from: .whitelistCheck, to: .turnTunnel))
        #expect(ConnectionStage.connectedDirect.state(of: .captcha) == .off)
    }
}
