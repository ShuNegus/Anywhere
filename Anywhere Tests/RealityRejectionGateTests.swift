//
//  RealityRejectionGateTests.swift
//  Anywhere
//
//  Backoff after a REALITY server rejects us: durations, reset, bypass, and the
//  app-group notice freshness rule.
//

import Foundation
import Synchronization
import Testing
@testable import Anywhere

private final class FakeClock: Sendable {
    private let value = Mutex<TimeInterval>(1_000)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private func makeKey(_ endpoint: String = "edge.example:443") -> RealityRejectionGate.Key {
    RealityRejectionGate.Key(
        endpoint: endpoint,
        serverName: "ya.ru",
        publicKey: Data(repeating: 7, count: 32),
        shortId: Data([0xab, 0xcd])
    )
}

struct RealityRejectionGateTests {

    @Test func blockDurationsDoubleUpToSixtySeconds() {
        let durations = (1...8).map { RealityRejectionGate.blockDuration(afterFailures: $0) }
        #expect(durations == [2, 4, 8, 16, 32, 60, 60, 60])
        #expect(RealityRejectionGate.blockDuration(afterFailures: 0) == 0)
        #expect(RealityRejectionGate.blockDuration(afterFailures: 1_000) == 60)
    }

    @Test func unknownServerIsNotBlocked() {
        let gate = RealityRejectionGate(now: { 0 })
        #expect(gate.remainingBlock(for: makeKey()) == nil)
        #expect(gate.refusal(for: makeKey()) == nil)
    }

    @Test func rejectionBlocksForBackoffThenExpires() throws {
        let clock = FakeClock()
        let gate = RealityRejectionGate(now: { clock.now })
        let key = makeKey()

        #expect(gate.recordRejection(for: key))
        #expect(gate.remainingBlock(for: key) == 2)
        let refusal = try #require(gate.refusal(for: key))
        guard case .tls(.reality(.rejectedRecently)) = refusal else {
            Issue.record("unexpected refusal \(refusal)")
            return
        }
        #expect(refusal.isRealityRejection)

        clock.advance(1.9)
        #expect(gate.remainingBlock(for: key) != nil)
        clock.advance(0.1)
        #expect(gate.remainingBlock(for: key) == nil)
        #expect(gate.refusal(for: key) == nil)
    }

    @Test func consecutiveRejectionsGrowTheBlock() {
        let clock = FakeClock()
        let gate = RealityRejectionGate(now: { clock.now })
        let key = makeKey()

        var observed: [TimeInterval] = []
        for _ in 0..<7 {
            #expect(gate.recordRejection(for: key))
            let remaining = gate.remainingBlock(for: key) ?? 0
            observed.append(remaining)
            clock.advance(remaining)
        }
        #expect(observed == [2, 4, 8, 16, 32, 60, 60])
    }

    @Test func rejectionsDuringABlockDoNotLengthenIt() {
        let clock = FakeClock()
        let gate = RealityRejectionGate(now: { clock.now })
        let key = makeKey()

        #expect(gate.recordRejection(for: key))
        // A burst of in-flight attempts that started before the block.
        for _ in 0..<50 { #expect(!gate.recordRejection(for: key)) }
        #expect(gate.remainingBlock(for: key) == 2)

        clock.advance(2)
        #expect(gate.recordRejection(for: key))
        #expect(gate.remainingBlock(for: key) == 4)
    }

    @Test func successResetsTheBackoff() {
        let clock = FakeClock()
        let gate = RealityRejectionGate(now: { clock.now })
        let key = makeKey()

        gate.recordRejection(for: key)
        clock.advance(2)
        gate.recordRejection(for: key)
        #expect(gate.recordSuccess(for: key))
        #expect(gate.remainingBlock(for: key) == nil)
        #expect(!gate.recordSuccess(for: key))

        gate.recordRejection(for: key)
        #expect(gate.remainingBlock(for: key) == 2)
    }

    @Test func serversAreTrackedIndependently() {
        let clock = FakeClock()
        let gate = RealityRejectionGate(now: { clock.now })
        let rejected = makeKey("a.example:443")
        let other = makeKey("b.example:443")

        gate.recordRejection(for: rejected)
        #expect(gate.refusal(for: rejected) != nil)
        #expect(gate.refusal(for: other) == nil)
    }

    @Test func latencyProbesBypassTheBlock() {
        let gate = RealityRejectionGate(now: { 0 })
        let key = makeKey()
        gate.recordRejection(for: key)

        #expect(gate.refusal(for: key) != nil)
        RealityRejectionGate.$bypass.withValue(true) {
            #expect(gate.refusal(for: key) == nil)
        }
        #expect(gate.refusal(for: key) != nil)
    }

    @Test func configurationKeyMatchesTheClientKey() throws {
        let configuration = try ProxyConfiguration.parse(
            url: "vless://00000000-0000-0000-0000-000000000001@edge.example:443?encryption=none&type=tcp&security=reality&sni=ya.ru&pbk=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA&sid=abcd#R"
        )
        let key = try #require(configuration.realityRejectionKey)
        #expect(key.endpoint == "edge.example:443")
        #expect(key.serverName == "ya.ru")
        #expect(key.shortId == Data([0xab, 0xcd]))
        #expect(configuration.realityRejectionKeys == [key])

        let plain = try ProxyConfiguration.parse(
            url: "vless://00000000-0000-0000-0000-000000000001@edge.example:443?encryption=none&type=tcp#P"
        )
        #expect(plain.realityRejectionKey == nil)
    }

    @Test func noticeIsFreshOnlyForTheSameServerAndRecently() {
        let key = makeKey()
        let record = (identity: key.identity, at: TimeInterval(10_000))
        #expect(RealityRejectionNotice.isFresh(record: record, keys: [key], now: 10_030))
        #expect(!RealityRejectionNotice.isFresh(record: record, keys: [key], now: 10_000 + RealityRejectionNotice.freshness + 1))
        #expect(!RealityRejectionNotice.isFresh(record: record, keys: [makeKey("other:443")], now: 10_030))
        #expect(!RealityRejectionNotice.isFresh(record: record, keys: [], now: 10_030))
    }
}
