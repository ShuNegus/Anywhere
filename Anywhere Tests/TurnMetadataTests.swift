//
//  TurnMetadataTests.swift
//  Anywhere
//

import Testing
import Foundation
@testable import Anywhere

struct TurnMetadataTests {

    /// Shape of a real subscription's `turn` block. All values here are invented.
    private static let singBoxDocument = """
    {
      "log": { "level": "info" },
      "dns": { "servers": [] },
      "turn": {
        "version": 1,
        "vk_link_required": true,
        "vk_link": "https://example.invalid/call/join/AAAAAAAAAAAAAAAA",
        "defaults": {
          "wrap_mode": true,
          "num_streams": 10,
          "ready_timeout": 30,
          "captcha_solver": "v2",
          "streams_per_cred": 2
        },
        "servers": {
          "alpha.example.invalid": {
            "peer_addr": "203.0.113.10:56000",
            "supported": true,
            "wrap_key_hex": "00112233445566778899aabbccddeeff"
          },
          "beta.example.invalid": {
            "peer_addr": "198.51.100.20:56000",
            "supported": false,
            "wrap_key_hex": "ffeeddccbbaa99887766554433221100"
          }
        }
      },
      "outbounds": []
    }
    """.data(using: .utf8)!

    @Test func extractsTurnBlockFromSingBoxDocument() throws {
        let metadata = try #require(TurnMetadata.extract(fromSingBoxJSON: Self.singBoxDocument))

        #expect(metadata.version == 1)
        #expect(metadata.vkLinkRequired == true)
        #expect(metadata.vkLink == "https://example.invalid/call/join/AAAAAAAAAAAAAAAA")
        #expect(metadata.servers.count == 2)

        let defaults = try #require(metadata.defaults)
        #expect(defaults.wrapMode == true)
        #expect(defaults.numStreams == 10)
        #expect(defaults.readyTimeout == 30)
        #expect(defaults.captchaSolver == "v2")
        #expect(defaults.streamsPerCred == 2)
    }

    @Test func foldsDictionaryKeyIntoServerHost() throws {
        let metadata = try #require(TurnMetadata.extract(fromSingBoxJSON: Self.singBoxDocument))

        let alpha = try #require(metadata.server(for: "alpha.example.invalid"))
        #expect(alpha.host == "alpha.example.invalid")
        #expect(alpha.peerAddr == "203.0.113.10:56000")
        #expect(alpha.wrapKeyHex == "00112233445566778899aabbccddeeff")
        #expect(alpha.supported)
        #expect(alpha.isUsable)

        let beta = try #require(metadata.server(for: "beta.example.invalid"))
        #expect(!beta.supported)
        #expect(!beta.isUsable)

        #expect(metadata.sortedServers.map(\.host) == ["alpha.example.invalid", "beta.example.invalid"])
        #expect(metadata.server(for: "gamma.example.invalid") == nil)
    }

    @Test func survivesAPersistenceRoundTrip() throws {
        let metadata = try #require(TurnMetadata.extract(fromSingBoxJSON: Self.singBoxDocument))
        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TurnMetadata.self, from: encoded)

        #expect(decoded == metadata)
        // The host must survive our own encoding, where it is a real field.
        #expect(decoded.server(for: "alpha.example.invalid")?.host == "alpha.example.invalid")
    }

    @Test func rejectsDocumentsWithoutUsableTurnBlock() {
        let cases = [
            #"{"outbounds": []}"#,                 // no turn block at all
            #"{"turn": {"version": 1, "servers": {}}}"#,  // turn block with no servers
            #"[{"turn": {}}]"#,                    // xray-json array, not an object
            "not json at all",
            "",
        ]
        for json in cases {
            #expect(TurnMetadata.extract(fromSingBoxJSON: Data(json.utf8)) == nil, "should reject: \(json)")
        }
    }

    @Test func toleratesAPartialTurnBlock() throws {
        let json = #"""
        {"turn": {"servers": {"solo.example.invalid": {"peer_addr": "192.0.2.1:56000"}}}}
        """#
        let metadata = try #require(TurnMetadata.extract(fromSingBoxJSON: Data(json.utf8)))

        #expect(metadata.version == 1)          // defaulted
        #expect(metadata.vkLink == nil)
        #expect(metadata.defaults == nil)

        let solo = try #require(metadata.server(for: "solo.example.invalid"))
        #expect(solo.peerAddr == "192.0.2.1:56000")
        #expect(solo.wrapKeyHex.isEmpty)
        #expect(!solo.supported)                 // absent means not supported
        #expect(!solo.isUsable)
    }
}

/// The credential-cache invariant: the Go core buckets sessions by
/// `streamID / streams_per_cred` and authenticates each bucket separately, so anything
/// below the session count means one VK captcha per extra bucket.
struct TurnDialerConfigTests {

    private static let server = TurnServerInfo(
        host: "alpha.example.invalid",
        supported: true,
        peerAddr: "203.0.113.10:56000",
        wrapKeyHex: "00112233445566778899aabbccddeeff"
    )

    private static func config(peers: Int, defaults: TurnDefaults?) -> [String: Any] {
        TurnDialerConfig.make(
            server: server,
            vkLink: "https://example.invalid/call/join/AAAAAAAAAAAAAAAA",
            defaults: defaults,
            peers: peers,
            manualCaptcha: false
        )
    }

    @Test(arguments: [1, 4, 5, 10, 50])
    func streamsPerCredNeverBelowNumStreams(peers: Int) throws {
        // The subscription's own suggestion (2) must not split the pool.
        let config = Self.config(peers: peers, defaults: TurnDefaults(streamsPerCred: 2))
        let numStreams = try #require(config["num_streams"] as? Int)
        let streamsPerCred = try #require(config["streams_per_cred"] as? Int)

        #expect(numStreams == peers)
        #expect(streamsPerCred >= numStreams, "would create \(numStreams / streamsPerCred) credential caches")
    }

    @Test func honoursALargerServerSuggestion() throws {
        let config = Self.config(peers: 10, defaults: TurnDefaults(streamsPerCred: 64))
        #expect(config["streams_per_cred"] as? Int == 64)
    }

    @Test func staysSingleCacheWithoutServerDefaults() throws {
        let config = Self.config(peers: 10, defaults: nil)
        #expect(config["num_streams"] as? Int == 10)
        #expect(config["streams_per_cred"] as? Int == 10)
    }

    /// Memory pressure trims the session count before it reaches the dialer; the
    /// credential math has to follow it down, not stay at the requested value.
    @Test func followsAMemoryTrimmedSessionCount() throws {
        let config = Self.config(peers: 4, defaults: TurnDefaults(streamsPerCred: 2))
        #expect(config["num_streams"] as? Int == 4)
        #expect(config["streams_per_cred"] as? Int == 4)
    }

    @Test func carriesWrapAndSolverSettings() throws {
        let config = Self.config(peers: 10, defaults: TurnDefaults(wrapMode: true, captchaSolver: "v2", streamsPerCred: 2))
        #expect(config["wrap_mode"] as? Bool == true)
        #expect(config["wrap_key_hex"] as? String == Self.server.wrapKeyHex)
        #expect(config["captcha_solver"] as? String == "v2")
        #expect(config["vless_mode"] as? Bool == true)
        #expect(config["peer_addr"] as? String == "203.0.113.10:56000")
    }
}
