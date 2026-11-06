//
//  SubscriptionPushStore.swift
//  Anywhere
//

import Foundation
import Synchronization

/// Per-subscription push state: the `push` block from the last successful refresh (its
/// `rev` is the revision now applied) and which APNs token was registered where.
///
/// Lives in the app's own `UserDefaults`, not in the synced `JSONBlobStore`: the applied
/// revision and the device token belong to this device, and syncing them would make one
/// device think another's refresh was its own.
nonisolated final class SubscriptionPushStore: Sendable {

    static let shared = SubscriptionPushStore()

    struct Entry: Codable, Equatable, Sendable {
        /// From the last successful refresh; `info.rev` is the applied revision.
        var info: SubscriptionPushInfo
        /// Token last accepted by `registeredURL`, so an unchanged pair is not re-sent.
        var registeredToken: String?
        var registeredURL: URL?

        func needsRegistration(of token: String) -> Bool {
            registeredToken != token || registeredURL != info.apnsRegisterURL
        }
    }

    private struct Persisted: Codable {
        var entries: [String: Entry] = [:]
        var deviceToken: String?
    }

    private static let defaultsKey = "anywhere.subscriptionPush.v1"
    /// `UserDefaults` is documented thread-safe but not marked `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let state: Mutex<Persisted>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) } ?? Persisted()
        state = Mutex(loaded)
    }

    // MARK: - Entries

    func entry(for id: UUID) -> Entry? {
        state.withLock { $0.entries[id.uuidString] }
    }

    func allEntries() -> [UUID: Entry] {
        state.withLock { persisted in
            persisted.entries.reduce(into: [UUID: Entry]()) { result, pair in
                if let id = UUID(uuidString: pair.key) { result[id] = pair.value }
            }
        }
    }

    /// Records the `push` block of a successful refresh. A new register URL forgets the
    /// old registration so the token gets sent to the new address.
    func setInfo(_ info: SubscriptionPushInfo?, for id: UUID) {
        mutate { persisted in
            guard let info else {
                persisted.entries.removeValue(forKey: id.uuidString)
                return
            }
            var entry = persisted.entries[id.uuidString] ?? Entry(info: info)
            entry.info = info
            persisted.entries[id.uuidString] = entry
        }
    }

    func markRegistered(token: String, url: URL, for id: UUID) {
        mutate { persisted in
            guard var entry = persisted.entries[id.uuidString] else { return }
            entry.registeredToken = token
            entry.registeredURL = url
            persisted.entries[id.uuidString] = entry
        }
    }

    @discardableResult
    func remove(_ id: UUID) -> Entry? {
        var removed: Entry?
        mutate { removed = $0.entries.removeValue(forKey: id.uuidString) }
        return removed
    }

    // MARK: - Device token

    var deviceToken: String? {
        state.withLock { $0.deviceToken }
    }

    func setDeviceToken(_ token: String) {
        mutate { $0.deviceToken = token }
    }

    // MARK: - Persistence

    private func mutate(_ body: (inout Persisted) -> Void) {
        let snapshot = state.withLock { persisted -> Persisted in
            body(&persisted)
            return persisted
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
