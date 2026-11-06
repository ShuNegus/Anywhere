//
//  SubscriptionStore.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Observation
import SwiftUI

nonisolated private let logger = AnywhereLogger(category: "SubscriptionStore")

@MainActor
@Observable
class SubscriptionStore {
    static let shared = SubscriptionStore()

    private(set) var subscriptions: [Subscription] = []
    private var tombstones: [Subscription] = []
    /// Backup route (TURN) status per subscription, for the icon next to its name.
    /// Device-local and outside iCloud sync: it reflects this device's last fetch.
    private(set) var turnAvailability: [UUID: TurnAvailability] = TurnAvailabilityPersistence.load()
    
    @ObservationIgnored private var loadedBlob: Data?
    @ObservationIgnored private var mutationEpoch = 0
    
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        let data = JSONBlobStore.shared.load(.subscriptions)
        loadedBlob = data
        let split = Self.decodeSplit(from: data)
        subscriptions = split.live
        tombstones = split.tombstones
    }

    func reload() async {
        while true {
            let previous = loadedBlob
            let epoch = mutationEpoch
            await saveTask?.value
            guard epoch == mutationEpoch else { continue }
            let outcome = await Task.detached(priority: .utility) {
                () -> (data: Data?, live: [Subscription], tombstones: [Subscription])? in
                let data = JSONBlobStore.shared.load(.subscriptions)
                guard data != previous else { return nil }
                let split = Self.decodeSplit(from: data)
                return (data, split.live, split.tombstones)
            }.value
            guard let outcome else { return }
            guard epoch == mutationEpoch else { continue }
            loadedBlob = outcome.data
            subscriptions = outcome.live
            tombstones = outcome.tombstones
            return
        }
    }

    // MARK: - CRUD

    func add(_ subscription: Subscription) {
        let tombstone = tombstones.first { $0.id == subscription.id }
        tombstones.removeAll { $0.id == subscription.id }
        var stamped = subscription
        stamped.updatedAt = SyncStamp.after(tombstone)
        subscriptions.append(stamped)
        save()
    }

    func update(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            var stamped = subscription
            stamped.updatedAt = SyncStamp.after(subscriptions[index])
            subscriptions[index] = stamped
            save()
        }
    }
    
    func delete(_ subscription: Subscription, configurationStore: ConfigurationStore? = nil) {
        let configurationStore = configurationStore ?? .shared
        configurationStore.deleteConfigurations(for: subscription.id)
        TurnMetadataStore.shared.removeMetadata(forSubscription: subscription.id)
        setTurnAvailability(nil, for: subscription.id)
        SubscriptionAutoRefresher.shared.subscriptionDeleted(subscription.id)
        subscriptions.removeAll { $0.id == subscription.id }
        recordTombstone(subscription)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        subscriptions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Persistence
    
    nonisolated private static func decodeSplit(from data: Data?) -> (live: [Subscription], tombstones: [Subscription]) {
        guard let data else { return ([], []) }
        guard let all = JSONDecoder().decodeSkippingInvalid([Subscription].self, from: data) else {
            JSONBlobStore.quarantine(.subscriptions, data)
            return ([], [])
        }
        return Tombstone.split(all)
    }
    
    private func recordTombstone(_ subscription: Subscription) {
        var tomb = Subscription(
            id: subscription.id,
            name: subscription.name,
            url: "",
            updatedAt: subscription.updatedAt
        )
        tomb.deletedAt = .now
        tombstones.removeAll { $0.id == subscription.id }
        tombstones.append(tomb)
    }

    private func save() {
        mutationEpoch += 1
        let snapshot = subscriptions + tombstones
        let previous = saveTask
        saveTask = Task.detached {
            await previous?.value
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                JSONBlobStore.shared.save(.subscriptions, data: data)
            } catch {
                logger.report(AnywhereError.store(.saveFailed(.subscriptions, underlying: error)))
            }
        }
    }
}

// MARK: - Backup route (TURN) status

extension SubscriptionStore {
    /// Stores what a `/turn` fetch said about a subscription: its metadata and the icon state.
    func applyTurnOutcome(_ outcome: TurnFetchOutcome, for id: UUID) {
        let hasManualLink = !AWCore.getTurnVKLink().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let resolved = TurnAvailabilityPolicy.resolve(
            outcome: outcome,
            previous: TurnMetadataStore.shared.metadata(forSubscription: id),
            hasManualVKLink: hasManualLink
        )
        if case .set(let metadata) = resolved.store {
            TurnMetadataStore.shared.setMetadata(metadata, forSubscription: id)
        }
        setTurnAvailability(resolved.availability, for: id)
    }

    /// The icon state, falling back to the stored metadata for subscriptions fetched
    /// before this status existed.
    func backupRoute(for id: UUID) -> TurnAvailability? {
        if let known = turnAvailability[id] { return known }
        guard let metadata = TurnMetadataStore.shared.metadata(forSubscription: id) else { return nil }
        let hasManualLink = !AWCore.getTurnVKLink().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TurnAvailabilityPolicy.availability(of: metadata, hasManualVKLink: hasManualLink)
    }

    fileprivate func setTurnAvailability(_ value: TurnAvailability?, for id: UUID) {
        guard turnAvailability[id] != value else { return }
        turnAvailability[id] = value
        TurnAvailabilityPersistence.save(turnAvailability)
    }
}

/// `UserDefaults` of the app, outside the synced blob store and the app group.
nonisolated enum TurnAvailabilityPersistence {
    private static let key = "anywhere.turnAvailability.v1"

    static func load() -> [UUID: TurnAvailability] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let keyed = try? JSONDecoder().decode([String: TurnAvailability].self, from: data) else { return [:] }
        return keyed.reduce(into: [:]) { result, pair in
            if let id = UUID(uuidString: pair.key) { result[id] = pair.value }
        }
    }

    static func save(_ map: [UUID: TurnAvailability]) {
        let keyed = map.reduce(into: [String: TurnAvailability]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(keyed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension SubscriptionStore {
    func subscription(for configuration: ProxyConfiguration) -> Subscription? {
        guard let subId = configuration.subscriptionId else { return nil }
        return subscriptions.first { $0.id == subId }
    }
    
    var pickerSections: [PickerSection] {
        let configStore = ConfigurationStore.shared
        return subscriptions.compactMap { subscription in
            let configs = configStore.configurations(for: subscription)
            guard !configs.isEmpty else { return nil }
            let marked = TurnAvailabilityPolicy.marksServers(
                hosts: configs.map(\.serverAddress),
                metadata: TurnMetadataStore.shared.metadata(forSubscription: subscription.id)
            )
            return PickerSection(
                id: subscription.id,
                header: subscription.name,
                items: configs.map {
                    PickerItem(id: $0.id, name: $0.name, marksBackupRoute: marked.contains($0.serverAddress))
                },
                backupRoute: AWCore.getTurnFeatureEnabled() ? backupRoute(for: subscription.id) : nil
            )
        }
    }

    func toggleCollapsed(_ subscription: Subscription) {
        var updated = subscription
        updated.collapsed.toggle()
        update(updated)
    }

    func rename(_ subscription: Subscription, to newName: String) {
        var updated = subscription
        updated.name = newName
        updated.isNameCustomized = true
        update(updated)
    }

    func add(_ subscription: Subscription, configurations newConfigurations: [ProxyConfiguration], turn: TurnMetadata? = nil, push: SubscriptionPushInfo? = nil, turnOutcome: TurnFetchOutcome? = nil) {
        add(subscription)
        applyTurnOutcome(turnOutcome ?? (turn.map { .loaded($0) } ?? .failed), for: subscription.id)
        SubscriptionAutoRefresher.shared.subscriptionFetched(subscription.id, push: push)
        let tagged = newConfigurations.map { configuration in
            ProxyConfiguration(
                id: configuration.id, name: configuration.name,
                serverAddress: configuration.serverAddress, serverPort: configuration.serverPort,
                subscriptionId: subscription.id,
                outbound: configuration.outbound
            )
        }
        ConfigurationStore.shared.replaceConfigurations(for: subscription.id, with: tagged)
    }
    
    func refresh(_ subscription: Subscription) async throws {
        let result = try await SubscriptionFetcher.fetch(url: subscription.url)
        
        let oldConfigurations = ConfigurationStore.shared.configurations(for: subscription)
        var oldByName: [String: [ProxyConfiguration]] = [:]
        for old in oldConfigurations {
            oldByName[old.name, default: []].append(old)
        }
        var oldNameCursor: [String: Int] = [:]

        var newConfigurations: [ProxyConfiguration] = []
        for configuration in result.configurations {
            let name = configuration.name
            let cursor = oldNameCursor[name, default: 0]
            let id: UUID
            if let group = oldByName[name], cursor < group.count {
                id = group[cursor].id
                oldNameCursor[name] = cursor + 1
            } else {
                id = configuration.id
            }
            newConfigurations.append(ProxyConfiguration(
                id: id, name: configuration.name,
                serverAddress: configuration.serverAddress, serverPort: configuration.serverPort,
                subscriptionId: subscription.id,
                outbound: configuration.outbound
            ))
        }

        ConfigurationStore.shared.replaceConfigurations(for: subscription.id, with: newConfigurations)

        // A refresh that comes back without a `turn` block clears the stale one, so a
        // relay withdrawn server-side stops being dialled. A failed fetch keeps it.
        applyTurnOutcome(result.turnOutcome, for: subscription.id)
        SubscriptionAutoRefresher.shared.subscriptionFetched(subscription.id, push: result.push)

        var updated = subscription
        updated.lastUpdate = Date()
        updated.upload = result.upload ?? subscription.upload
        updated.download = result.download ?? subscription.download
        updated.total = result.total ?? subscription.total
        updated.expire = result.expire ?? subscription.expire
        if let name = result.name, !updated.isNameCustomized {
            updated.name = name
        }
        update(updated)
    }
}
