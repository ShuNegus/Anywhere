//
//  SubscriptionPushTests.swift
//  Anywhere
//

import Testing
import Foundation
@testable import Anywhere

/// Forced subscription refresh: the `push` block, the refresh policy and the store.
/// All values here are invented.
struct SubscriptionPushTests {

    private static let withTurn = """
    {"turn": {"version": 1, "servers": {"alpha.example.invalid": {"peer_addr": "203.0.113.10:56000",
       "supported": true, "wrap_key_hex": "00112233445566778899aabbccddeeff"}}},
     "push": {"rev": 7, "rev_url": "https://sub.example.invalid/AbC/rev",
              "apns_register_url": "https://sub.example.invalid/AbC/push/apns"}}
    """

    private static let pushOnly = """
    {"push": {"rev": 0, "rev_url": "https://sub.example.invalid/AbC/rev",
              "apns_register_url": "https://sub.example.invalid/AbC/push/apns"}}
    """

    // MARK: - Parsing

    @Test func parsesPushBlockNextToTurn() throws {
        let data = Data(Self.withTurn.utf8)
        let push = try #require(SubscriptionPushInfo.extract(from: data))
        #expect(push.rev == 7)
        #expect(push.revURL.absoluteString == "https://sub.example.invalid/AbC/rev")
        #expect(push.apnsRegisterURL.absoluteString == "https://sub.example.invalid/AbC/push/apns")
        #expect(TurnMetadata.extract(fromSingBoxJSON: data)?.servers.count == 1)
    }

    @Test func parsesPushBlockWithoutTurn() throws {
        let data = Data(Self.pushOnly.utf8)
        let push = try #require(SubscriptionPushInfo.extract(from: data))
        #expect(push.rev == 0)
        #expect(TurnMetadata.extract(fromSingBoxJSON: data) == nil)
    }

    @Test func rejectsMissingOrBrokenPushBlock() {
        #expect(SubscriptionPushInfo.extract(from: Data(#"{"turn": {}}"#.utf8)) == nil)
        #expect(SubscriptionPushInfo.extract(from: Data(#"{"push": {"rev": 1}}"#.utf8)) == nil)
        #expect(SubscriptionPushInfo.extract(from: Data(
            #"{"push": {"rev": 1, "rev_url": "ftp://x.invalid/r", "apns_register_url": "https://x.invalid/a"}}"#.utf8
        )) == nil)
        #expect(SubscriptionPushInfo.extract(from: Data("not json".utf8)) == nil)
    }

    @Test func parsesRevisionResponse() {
        #expect(SubscriptionPushInfo.parseRevision(Data(#"{"rev": 12}"#.utf8)) == 12)
        #expect(SubscriptionPushInfo.parseRevision(Data(#"{"error": "x"}"#.utf8)) == nil)
        #expect(SubscriptionPushInfo.parseRevision(Data("<html>".utf8)) == nil)
    }

    // MARK: - Policy

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func refreshesWhenNeverFetchedOrOlderThanADay() {
        #expect(SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: nil, now: now, appliedRev: nil, serverRev: nil))
        #expect(SubscriptionRefreshPolicy.shouldRefresh(
            lastUpdate: now.addingTimeInterval(-24 * 3600), now: now, appliedRev: 3, serverRev: 3))
        #expect(!SubscriptionRefreshPolicy.shouldRefresh(
            lastUpdate: now.addingTimeInterval(-23 * 3600), now: now, appliedRev: 3, serverRev: 3))
    }

    @Test func refreshesOnNewerRevisionOnly() {
        let fresh = now.addingTimeInterval(-60)
        #expect(SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: 3, serverRev: 4))
        #expect(!SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: 4, serverRev: 4))
        #expect(!SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: 5, serverRev: 4))
        // Unreachable revision endpoint: nothing to compare, nothing to do.
        #expect(!SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: 3, serverRev: nil))
        // No revision on file yet: any published one beyond 0 is news.
        #expect(SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: nil, serverRev: 1))
        #expect(!SubscriptionRefreshPolicy.shouldRefresh(lastUpdate: fresh, now: now, appliedRev: nil, serverRev: 0))
    }

    // MARK: - Store

    private func makeStore() -> (SubscriptionPushStore, UserDefaults) {
        let suite = "SubscriptionPushTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SubscriptionPushStore(defaults: defaults), defaults)
    }

    private func info(rev: Int, register: String = "https://sub.example.invalid/AbC/push/apns") -> SubscriptionPushInfo {
        SubscriptionPushInfo(
            rev: rev,
            revURL: URL(string: "https://sub.example.invalid/AbC/rev")!,
            apnsRegisterURL: URL(string: register)!
        )
    }

    @Test func storePersistsAndTracksRegistration() throws {
        let (store, defaults) = makeStore()
        let id = UUID()
        store.setInfo(info(rev: 2), for: id)
        store.setDeviceToken("aabb")

        var entry = try #require(store.entry(for: id))
        #expect(entry.info.rev == 2)
        #expect(entry.needsRegistration(of: "aabb"))

        store.markRegistered(token: "aabb", url: entry.info.apnsRegisterURL, for: id)
        entry = try #require(store.entry(for: id))
        #expect(!entry.needsRegistration(of: "aabb"))
        #expect(entry.needsRegistration(of: "ccdd"))

        // A new revision keeps the registration; a new register URL asks for a new one.
        store.setInfo(info(rev: 3), for: id)
        #expect(store.entry(for: id)?.needsRegistration(of: "aabb") == false)
        store.setInfo(info(rev: 3, register: "https://other.example.invalid/AbC/push/apns"), for: id)
        #expect(store.entry(for: id)?.needsRegistration(of: "aabb") == true)

        // Survives a fresh instance over the same defaults.
        let reopened = SubscriptionPushStore(defaults: defaults)
        #expect(reopened.entry(for: id)?.info.rev == 3)
        #expect(reopened.deviceToken == "aabb")

        #expect(reopened.remove(id) != nil)
        #expect(reopened.entry(for: id) == nil)
    }

    @Test func recognisesOnlyOurSilentPush() {
        let ours: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "anywhere": ["action": "refresh_subscription", "rev": 4] as [String: Any],
        ]
        let iCloud: [AnyHashable: Any] = ["aps": ["content-available": 1], "ck": ["cid": "x"]]
        let otherAction: [AnyHashable: Any] = ["anywhere": ["action": "something_else"]]

        let oursMatches = SubscriptionAutoRefresher.isRefreshPush(ours)
        let iCloudMatches = SubscriptionAutoRefresher.isRefreshPush(iCloud)
        let otherMatches = SubscriptionAutoRefresher.isRefreshPush(otherAction)
        #expect(oursMatches)
        #expect(iCloudMatches == false)
        #expect(otherMatches == false)
    }
}
