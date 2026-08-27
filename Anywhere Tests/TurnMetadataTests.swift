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
