//
//  ConnectionStageTests.swift
//  Anywhere
//

import Foundation
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
        turnUsable: Bool? = nil,
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
            turnUsable: turnUsable,
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

    // MARK: - Пул обхода, который уже работает

    /// Ядро берёт следующий набор кредов (и, может быть, капчу) только когда реле
    /// заполнило текущий, — часто уже при работающем туннеле. Такая капча не должна
    /// откатывать граф с «Подключено».
    @Test func aUsablePoolStaysConnectedThroughACaptcha() {
        #expect(resolve(autoDecision: .turn, turnPhase: .captchaWait, turnUsable: true,
                        captchaPending: true, captchaSeen: true)
                == .connectedViaTurn(captchaSolved: true))
        #expect(resolve(autoDecision: .turn, turnPhase: .tunnelSetup, turnUsable: true)
                == .connectedViaTurn(captchaSolved: false))
    }

    /// Пока пул ничего не возит, капча — этап, а «ready» старой фазы не в счёт.
    @Test func anUnusablePoolWalksTheBranch() {
        #expect(resolve(autoDecision: .turn, turnPhase: .captchaWait, turnUsable: false) == .captcha)
        #expect(resolve(autoDecision: .turn, turnPhase: .vkAccess, turnUsable: false,
                        captchaPending: true) == .captcha)
        #expect(resolve(autoDecision: .turn, turnPhase: .ready, turnUsable: false) == .turnTunnel)
    }

    @Test func connectedTitleTellsAboutPeersBeingAdded() {
        func pool(sessions: Int, target: Int, fetch: TurnCoreStatus.FetchState, usable: Bool = true) -> TurnPoolSummary {
            TurnPoolSummary(usable: usable, sessions: sessions, target: target, fetch: fetch,
                            captchas: 1, setsObtained: 1)
        }
        let plain = ConnectionGraphNode.connected.title
        #expect(ConnectionGraphNode.connected.title(pool: nil) == plain)
        #expect(ConnectionGraphNode.connected.title(pool: pool(sessions: 40, target: 40, fetch: .idle)) == plain)
        // Сессии переподключаются, но добирать нечего — это не «добираем пиры».
        #expect(ConnectionGraphNode.connected.title(pool: pool(sessions: 38, target: 40, fetch: .idle)) == plain)

        let adding = ConnectionGraphNode.connected.title(pool: pool(sessions: 20, target: 40, fetch: .fetching))
        #expect(adding != plain && adding.contains("20/40"))

        let captcha = ConnectionGraphNode.connected.title(pool: pool(sessions: 20, target: 40, fetch: .captchaWait))
        #expect(captcha != plain && captcha != adding)

        // Подпись только у «Подключено».
        for node in ConnectionGraphNode.allCases where node != .connected {
            #expect(node.title(pool: pool(sessions: 20, target: 40, fetch: .captchaWait)) == node.title)
        }
    }

    // MARK: - Статус ядра

    /// Формат `clientcore.Status` из `StatusJSON()` — snake_case.
    @Test func coreStatusDecodesTheGoSnapshot() throws {
        let json = """
        {"version":1,"usable":true,"sessions":20,"target":40,"phase":4,
         "fetch":{"state":"captcha_wait","set_id":1,"waiting":20},
         "sets_obtained":1,"sets_retired":0,"captchas":2,
         "sets":[{"id":0,"state":"full","active":20,"pending":0,"capacity":20}]}
        """
        let status = try #require(TurnCoreStatus.decode(coreJSON: json))
        #expect(status.usable && status.sessions == 20 && status.target == 40)
        #expect(status.fetch.state == .captchaWait && status.fetch.setId == 1 && status.fetch.waiting == 20)
        #expect(status.fetch.backoffMs == nil)
        #expect(status.sets.first?.capacity == 20)

        // Неизвестное состояние от более нового ядра не роняет разбор.
        let newer = json.replacingOccurrences(of: "captcha_wait", with: "something_new")
        #expect(TurnCoreStatus.decode(coreJSON: newer)?.fetch.state == .unknown)
        // Другая версия формата — полям не доверяем.
        #expect(TurnCoreStatus.decode(coreJSON: json.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")) == nil)
        #expect(TurnCoreStatus.decode(coreJSON: "") == nil)
    }

    @Test func poolSummaryCombinesRelays() throws {
        func status(usable: Bool, sessions: Int, fetch: String, captchas: Int) throws -> TurnCoreStatus {
            try #require(TurnCoreStatus.decode(coreJSON: """
            {"version":1,"usable":\(usable),"sessions":\(sessions),"target":20,"phase":4,
             "fetch":{"state":"\(fetch)","set_id":-1,"waiting":0},
             "sets_obtained":1,"sets_retired":0,"captchas":\(captchas),"sets":[]}
            """))
        }
        #expect(TurnPoolSummary(combining: []) == nil)
        let pool = try #require(TurnPoolSummary(combining: [
            try status(usable: false, sessions: 0, fetch: "fetching", captchas: 0),
            try status(usable: true, sessions: 12, fetch: "captcha_auto", captchas: 1),
        ]))
        #expect(pool.usable && pool.sessions == 12 && pool.target == 40)
        #expect(pool.fetch == .captchaAuto) // the more urgent of the two
        #expect(pool.captchas == 1 && pool.setsObtained == 2)
    }

    /// Счётчики приходят из расширения по IPC: их отсутствие (старое расширение)
    /// должно декодироваться в `nil`, а не ронять разбор статистики.
    @Test func statisticsDecodeWithoutCredentialCounters() throws {
        let json = Data("""
        {"host":"relay.example","sessions":4,"streams":2,"phase":5}
        """.utf8)
        let stats = try JSONDecoder().decode(TurnHostStatistics.self, from: json)
        #expect(stats.credentialSets == nil)
        #expect(stats.credentialSetsPassed == nil)
        #expect(stats.captchaHits == nil)
        #expect(stats.phase == 5)
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
