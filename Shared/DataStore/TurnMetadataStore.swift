//
//  TurnMetadataStore.swift
//  Anywhere
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnMetadataStore")

/// TURN metadata delivered alongside each subscription, kept in the app group so the
/// Network Extension can read it without any IPC.
///
/// Keyed by `Subscription.id`, mirroring how `ConfigurationStore` tags configurations.
/// The payload lives in a plain file (the `AWCore.setMITMData` pattern) rather than in
/// the synced `JSONBlobStore`: it is refetched with every subscription refresh and is
/// tied to one account, so syncing it across devices would only invite staleness.
nonisolated final class TurnMetadataStore: Sendable {

    static let shared = TurnMetadataStore()

    private struct State {
        var loaded = false
        var modified: Date?
        var bySubscription: [UUID: TurnMetadata] = [:]
    }

    private let state = Mutex(State())

    private init() {}

    // MARK: - Reading

    /// Metadata for one subscription, or `nil` if that subscription carries none.
    func metadata(forSubscription id: UUID) -> TurnMetadata? {
        reloadIfNeeded()
        return state.withLock { $0.bySubscription[id] }
    }

    /// Everything on file, newest read wins.
    func all() -> [UUID: TurnMetadata] {
        reloadIfNeeded()
        return state.withLock { $0.bySubscription }
    }

    /// Looks a relay up by proxy host across every subscription.
    ///
    /// A host normally appears in exactly one subscription; when it appears in more than
    /// one, a usable entry wins over an unusable one, and ties are broken by host order
    /// so the answer is stable.
    func server(for host: String) -> TurnServerInfo? {
        reloadIfNeeded()
        let needle = host.lowercased()
        let candidates = state.withLock { $0.bySubscription }
            .values
            .compactMap { $0.server(for: needle) }
        return candidates.first(where: { $0.isUsable }) ?? candidates.first
    }

    /// The dialer knobs to use for `host`, taken from the subscription that owns it.
    func defaults(for host: String) -> TurnDefaults? {
        reloadIfNeeded()
        let needle = host.lowercased()
        return state.withLock { $0.bySubscription }
            .values
            .first { $0.server(for: needle) != nil }?
            .defaults
    }

    /// The VK Calls link the subscription shipped, if any. When several subscriptions
    /// carry one, the first non-empty link wins.
    func subscriptionVKLink() -> String? {
        reloadIfNeeded()
        return state.withLock { $0.bySubscription }
            .values
            .compactMap { $0.vkLink }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Every known relay, deduplicated by host and sorted for display.
    func allServers() -> [TurnServerInfo] {
        reloadIfNeeded()
        var byHost: [String: TurnServerInfo] = [:]
        for metadata in state.withLock({ $0.bySubscription }).values {
            for (host, server) in metadata.servers where byHost[host] == nil || !byHost[host]!.isUsable {
                byHost[host] = server
            }
        }
        return byHost.values.sorted { $0.host < $1.host }
    }

    // MARK: - Writing

    /// Records (or, with `nil`, clears) the metadata for one subscription.
    func setMetadata(_ metadata: TurnMetadata?, forSubscription id: UUID) {
        reloadIfNeeded()
        let snapshot: [UUID: TurnMetadata] = state.withLock {
            if let metadata {
                $0.bySubscription[id] = metadata
            } else {
                $0.bySubscription.removeValue(forKey: id)
            }
            return $0.bySubscription
        }
        persist(snapshot)
    }

    func removeMetadata(forSubscription id: UUID) {
        setMetadata(nil, forSubscription: id)
    }

    // MARK: - Persistence

    private func persist(_ snapshot: [UUID: TurnMetadata]) {
        let keyed = snapshot.reduce(into: [String: TurnMetadata]()) { $0[$1.key.uuidString] = $1.value }
        do {
            let data = try JSONEncoder().encode(keyed)
            AWCore.setTurnData(data)
            state.withLock { $0.modified = AWCore.turnDataModificationDate() }
        } catch {
            logger.report(AnywhereError.store(.saveFailed(.turnPayload, underlying: error)))
        }
    }

    /// Re-reads the backing file when it has changed underneath us. Both processes hold
    /// their own cache, so the extension picks up an edit made by the app.
    private func reloadIfNeeded() {
        let modified = AWCore.turnDataModificationDate()
        let needsLoad = state.withLock { !$0.loaded || $0.modified != modified }
        guard needsLoad else { return }

        var decoded: [UUID: TurnMetadata] = [:]
        if let data = AWCore.getTurnData(),
           let keyed = try? JSONDecoder().decode([String: TurnMetadata].self, from: data) {
            for (key, value) in keyed {
                guard let id = UUID(uuidString: key) else { continue }
                decoded[id] = value
            }
        }
        state.withLock {
            $0.bySubscription = decoded
            $0.modified = modified
            $0.loaded = true
        }
    }
}
