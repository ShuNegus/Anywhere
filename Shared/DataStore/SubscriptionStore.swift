//
//  SubscriptionStore.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
class SubscriptionStore {
    private(set) var subscriptions: [Subscription] = []
    private var tombstones: [Subscription] = []

    @ObservationIgnored private let syncStore: SyncStore
    @ObservationIgnored private var loadedItems: [Data]?
    /// Backup route (TURN) status per subscription, for the icon next to its name.
    /// Device-local and outside iCloud sync: it reflects this device's last fetch.
    private(set) var turnAvailability: [UUID: TurnAvailability] = TurnAvailabilityPersistence.load()

    @ObservationIgnored private var mutationEpoch = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(syncStore: SyncStore) {
        self.syncStore = syncStore
        let items = syncStore.loadItems(.subscriptions)
        loadedItems = items
        let split = Self.decodeSplit(from: items)
        subscriptions = split.live
        tombstones = split.tombstones
    }

    func reload() async {
        while true {
            let previous = loadedItems
            let epoch = mutationEpoch
            await saveTask?.value
            guard epoch == mutationEpoch else { continue }
            let outcome = await Task.detached(priority: .utility) {
                [syncStore] () -> (items: [Data], live: [Subscription], tombstones: [Subscription])? in
                let items = syncStore.loadItems(.subscriptions)
                guard items != previous else { return nil }
                let split = Self.decodeSplit(from: items)
                return (items, split.live, split.tombstones)
            }.value
            guard let outcome else { return }
            guard epoch == mutationEpoch else { continue }
            loadedItems = outcome.items
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
    
    private func mutate(id: UUID, _ apply: (inout Subscription) -> Void) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var record = subscriptions[index]
        apply(&record)
        record.updatedAt = SyncStamp.after(subscriptions[index])
        subscriptions[index] = record
        save()
    }
    
    func delete(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        recordTombstone(subscription)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        subscriptions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Persistence
    
    nonisolated private static func decodeSplit(from items: [Data]) -> (live: [Subscription], tombstones: [Subscription]) {
        Tombstone.split(SyncCodec.decodeItems(Subscription.self, key: .subscriptions, payloads: items))
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
        let live = subscriptions
        let snapshot = live + tombstones
        let previous = saveTask
        saveTask = Task.detached { [syncStore] in
            await previous?.value
            syncStore.save(.subscriptions, items: SyncCodec.encodeItems(snapshot), order: SyncCodec.order(of: live))
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

    func setTurnAvailability(_ value: TurnAvailability?, for id: UUID) {
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

    /// One section per subscription for the home screen's server list, with the backup
    /// route status of the subscription and the servers it reaches.
    func pickerSections(configurationStore: ConfigurationStore) -> [PickerSection] {
        subscriptions.compactMap { subscription in
            let configs = configurationStore.configurations(for: subscription)
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

    func rename(_ subscription: Subscription, to newName: String) {
        mutate(id: subscription.id) {
            $0.name = newName
            $0.isNameCustomized = true
        }
    }

    
    func applyRefreshResult(_ result: SubscriptionFetcher.Result, to subscriptionId: UUID) {
        mutate(id: subscriptionId) { record in
            record.lastUpdate = Date()
            record.upload = result.upload ?? record.upload
            record.download = result.download ?? record.download
            record.total = result.total ?? record.total
            record.expire = result.expire ?? record.expire
            record.iconLight = result.iconLight
            record.iconDark = result.iconDark
            if let name = result.name, !record.isNameCustomized {
                record.name = name
            }
        }
    }
}
