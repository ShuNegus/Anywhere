//
//  SubscriptionPushInfo.swift
//  Anywhere
//

import Foundation

/// The `push` block served next to a subscription by the `<subscription>/turn` endpoint:
/// the subscription's current revision plus where to poll it and where to register an
/// APNs token. Bumping the revision server-side asks every client to refresh.
///
/// Both URLs come from the server — the app never derives them, so a token is only ever
/// sent to an address the subscription's own server handed out.
nonisolated struct SubscriptionPushInfo: Codable, Equatable, Sendable {
    let rev: Int
    let revURL: URL
    let apnsRegisterURL: URL

    enum CodingKeys: String, CodingKey {
        case rev
        case revURL = "rev_url"
        case apnsRegisterURL = "apns_register_url"
    }

    /// Pulls the `push` block out of a `/turn` response. The `turn` block may be absent
    /// (a user with no relays), so this is read independently of it.
    static func extract(from data: Data) -> SubscriptionPushInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let push = object["push"],
              let pushData = try? JSONSerialization.data(withJSONObject: push),
              let info = try? JSONDecoder().decode(SubscriptionPushInfo.self, from: pushData),
              Self.isWebURL(info.revURL), Self.isWebURL(info.apnsRegisterURL) else {
            return nil
        }
        return info
    }

    /// Reads `{"rev": N}` from the revision endpoint.
    static func parseRevision(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["rev"] as? NSNumber)?.intValue
    }

    private static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && !(url.host ?? "").isEmpty
    }
}

/// When a subscription should be refreshed without the user asking.
nonisolated enum SubscriptionRefreshPolicy {
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// Too old (or never fetched) — refresh regardless of the revision.
    static func isStale(lastUpdate: Date?, now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= maxAge
    }

    /// The server published a newer revision than the one last applied.
    static func hasNewRevision(applied: Int?, server: Int?) -> Bool {
        guard let server else { return false }
        return server > (applied ?? 0)
    }

    static func shouldRefresh(lastUpdate: Date?, now: Date, appliedRev: Int?, serverRev: Int?) -> Bool {
        isStale(lastUpdate: lastUpdate, now: now) || hasNewRevision(applied: appliedRev, server: serverRev)
    }
}
