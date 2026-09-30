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

/// The config handed to the Go core. Credential sets are the core's business: it fills
/// one VK set until the relay refuses it and only then fetches another (and its
/// captcha), so no `streams_per_cred` goes out — a fixed split would only ask for
/// captchas the relay never needed.
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

    @Test(arguments: [1, 4, 10, 30, 50])
    func leavesCredentialSetsToTheCore(peers: Int) throws {
        // Whatever the subscription suggests (2 in real ones, 64 in odd ones).
        for suggestion in [nil, 2, 64] {
            let config = Self.config(peers: peers, defaults: TurnDefaults(streamsPerCred: suggestion))
            #expect(config["num_streams"] as? Int == peers)
            #expect(config["streams_per_cred"] == nil)
        }
    }

    /// Memory pressure trims the session count before it reaches the dialer.
    @Test func carriesAMemoryTrimmedSessionCount() throws {
        let config = Self.config(peers: 4, defaults: nil)
        #expect(config["num_streams"] as? Int == 4)
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

/// Holding the power button forces one session through TURN: every routing decision
/// reads the effective mode, while the stored setting stays what the user chose.
@Suite(.serialized)
struct TurnForceTests {

    @Test func forcedSessionIsOnWhateverTheModeSays() {
        let savedMode = AWCore.getTurnMode()
        let savedFeature = AWCore.getTurnFeatureEnabled()
        let savedForced = AWCore.getTurnForced()
        defer {
            AWCore.setTurnMode(savedMode)
            AWCore.setTurnFeatureEnabled(savedFeature)
            AWCore.setTurnForced(savedForced)
        }

        AWCore.setTurnFeatureEnabled(false)
        for mode in [TurnMode.off, .auto, .on] {
            AWCore.setTurnMode(mode)
            AWCore.setTurnForced(true)
            #expect(AWCore.getEffectiveTurnMode() == .on)
            #expect(AWCore.getTurnActiveForSession())
            #expect(AWCore.getTurnMode() == mode, "the stored setting must not change")

            AWCore.setTurnForced(false)
            #expect(AWCore.getEffectiveTurnMode() == mode)
            #expect(!AWCore.getTurnActiveForSession())
        }
    }
}
