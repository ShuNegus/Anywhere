//
//  TurnMetadata.swift
//  Anywhere
//

import Foundation

/// One vk-turn relay endpoint, as advertised by the subscription.
///
/// `host` is not a field in the wire format — it is the key of the `servers`
/// dictionary, and is folded into the value while decoding.
nonisolated struct TurnServerInfo: Codable, Hashable, Sendable, Identifiable {
    let host: String
    let supported: Bool
    let peerAddr: String
    let wrapKeyHex: String

    var id: String { host }

    enum CodingKeys: String, CodingKey {
        case host
        case supported
        case peerAddr = "peer_addr"
        case wrapKeyHex = "wrap_key_hex"
    }

    init(host: String, supported: Bool, peerAddr: String, wrapKeyHex: String) {
        self.host = host
        self.supported = supported
        self.peerAddr = peerAddr
        self.wrapKeyHex = wrapKeyHex
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `host` is absent in the subscription payload (it is the dictionary key) but
        // present when we re-decode our own persisted copy.
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
        supported = (try? container.decode(Bool.self, forKey: .supported)) ?? false
        peerAddr = (try? container.decode(String.self, forKey: .peerAddr)) ?? ""
        wrapKeyHex = (try? container.decode(String.self, forKey: .wrapKeyHex)) ?? ""
    }

    /// A copy carrying the host it was filed under.
    func withHost(_ host: String) -> TurnServerInfo {
        TurnServerInfo(host: host, supported: supported, peerAddr: peerAddr, wrapKeyHex: wrapKeyHex)
    }

    /// Usable only when the relay is marked supported and actually addressable.
    var isUsable: Bool {
        supported && !peerAddr.isEmpty && !host.isEmpty
    }
}

/// Dialer knobs the server suggests. Every field is optional; the client falls back
/// to its own defaults (and to the user's Peers preference) for anything missing.
nonisolated struct TurnDefaults: Codable, Hashable, Sendable {
    let wrapMode: Bool?
    let numStreams: Int?
    let readyTimeout: Int?
    let captchaSolver: String?
    let streamsPerCred: Int?

    enum CodingKeys: String, CodingKey {
        case wrapMode = "wrap_mode"
        case numStreams = "num_streams"
        case readyTimeout = "ready_timeout"
        case captchaSolver = "captcha_solver"
        case streamsPerCred = "streams_per_cred"
    }

    init(wrapMode: Bool? = nil, numStreams: Int? = nil, readyTimeout: Int? = nil,
         captchaSolver: String? = nil, streamsPerCred: Int? = nil) {
        self.wrapMode = wrapMode
        self.numStreams = numStreams
        self.readyTimeout = readyTimeout
        self.captchaSolver = captchaSolver
        self.streamsPerCred = streamsPerCred
    }
}

/// The `turn` block of a sing-box-flavoured subscription response.
nonisolated struct TurnMetadata: Codable, Hashable, Sendable {
    let version: Int
    let vkLink: String?
    let vkLinkRequired: Bool?
    let defaults: TurnDefaults?
    let servers: [String: TurnServerInfo]

    enum CodingKeys: String, CodingKey {
        case version
        case vkLink = "vk_link"
        case vkLinkRequired = "vk_link_required"
        case defaults
        case servers
    }

    init(version: Int, vkLink: String? = nil, vkLinkRequired: Bool? = nil,
         defaults: TurnDefaults? = nil, servers: [String: TurnServerInfo] = [:]) {
        self.version = version
        self.vkLink = vkLink
        self.vkLinkRequired = vkLinkRequired
        self.defaults = defaults
        self.servers = servers.reduce(into: [:]) { $0[$1.key] = $1.value.withHost($1.key) }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        vkLink = try? container.decodeIfPresent(String.self, forKey: .vkLink)
        vkLinkRequired = try? container.decodeIfPresent(Bool.self, forKey: .vkLinkRequired)
        defaults = try? container.decodeIfPresent(TurnDefaults.self, forKey: .defaults)
        let raw = (try? container.decode([String: TurnServerInfo].self, forKey: .servers)) ?? [:]
        // Fold the dictionary key into each value so a server can travel on its own.
        servers = raw.reduce(into: [:]) { $0[$1.key] = $1.value.withHost($1.key) }
    }

    /// Servers sorted by host, for stable display.
    var sortedServers: [TurnServerInfo] {
        servers.values.sorted { $0.host < $1.host }
    }

    func server(for host: String) -> TurnServerInfo? {
        servers[host.lowercased()] ?? servers[host]
    }

    /// Decodes the `turn` block out of a full sing-box subscription document.
    /// Returns `nil` for anything that is not a JSON object carrying a usable `turn`.
    static func extract(fromSingBoxJSON data: Data) -> TurnMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turn = object["turn"],
              let turnData = try? JSONSerialization.data(withJSONObject: turn) else {
            return nil
        }
        guard let metadata = try? JSONDecoder().decode(TurnMetadata.self, from: turnData),
              !metadata.servers.isEmpty else {
            return nil
        }
        return metadata
    }
}
