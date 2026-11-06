//
//  SubscriptionFetcherTurnTests.swift
//  Anywhere
//

import Testing
import Foundation
@testable import Anywhere

/// The dedicated `<subscription>/turn` endpoint. All values here are invented.
struct SubscriptionFetcherTurnTests {

    private func endpoint(_ string: String) -> String? {
        URL(string: string).flatMap { SubscriptionFetcher.turnEndpointURL(for: $0) }?.absoluteString
    }

    @Test func appendsTurnToSubscriptionPath() {
        #expect(endpoint("https://sub.example.invalid/AbC-123_x") == "https://sub.example.invalid/AbC-123_x/turn")
    }

    @Test func trailingSlashIsNotDoubled() {
        #expect(endpoint("https://sub.example.invalid/AbC/") == "https://sub.example.invalid/AbC/turn")
    }

    @Test func keepsPortAndQueryDropsFragment() {
        #expect(endpoint("http://sub.example.invalid:8080/p/AbC?x=1#name") == "http://sub.example.invalid:8080/p/AbC/turn?x=1")
    }

    @Test func rejectsURLsWithoutPathOrHTTPScheme() {
        #expect(endpoint("https://sub.example.invalid") == nil)
        #expect(endpoint("https://sub.example.invalid/") == nil)
        #expect(endpoint("ftp://sub.example.invalid/AbC") == nil)
    }

    @Test func endpointResponseParsesWithExistingExtractor() throws {
        let body = """
        {"turn": {"version": 1, "vk_link_required": true,
          "vk_link": "https://example.invalid/call/join/AAAA",
          "defaults": {"wrap_mode": true, "num_streams": 10},
          "servers": {"alpha.example.invalid": {"peer_addr": "203.0.113.10:56000",
            "supported": true, "wrap_key_hex": "00112233445566778899aabbccddeeff"}}}}
        """
        let metadata = try #require(TurnMetadata.extract(fromSingBoxJSON: Data(body.utf8)))
        #expect(metadata.servers.count == 1)
        #expect(metadata.vkLink == "https://example.invalid/call/join/AAAA")
    }
}
