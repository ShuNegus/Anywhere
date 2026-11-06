//
//  SubscriptionAutoRefresher.swift
//  Anywhere
//

import Foundation

nonisolated private let logger = AnywhereLogger(category: "SubscriptionAutoRefresher")

/// Refreshes subscriptions without the user asking, and keeps the APNs token registered
/// with each subscription's server.
///
/// A subscription is refreshed when it is older than 24 hours or when its server has
/// published a newer revision (`SubscriptionRefreshPolicy`). Triggers: app launch and
/// activation, the background refresh task, and a silent push from the server. All of it
/// is quiet — failures go to the log, never to an alert.
@MainActor
final class SubscriptionAutoRefresher {

    static let shared = SubscriptionAutoRefresher()

    enum Outcome: Sendable {
        case refreshed, noChange, failed
    }

    private let pushStore = SubscriptionPushStore.shared
    private var running: Task<Outcome, Never>?
    private var lastRun: Date?
    /// Activation can fire in bursts (control centre, app switcher); a check this soon
    /// after the previous one adds nothing.
    private static let minimumInterval: TimeInterval = 60

    private init() {}

    // MARK: - Refresh

    /// Checks every subscription and refreshes the ones that need it, one at a time.
    /// Concurrent calls share the run in progress.
    @discardableResult
    func run(reason: String, force: Bool = false) async -> Outcome {
        if let running {
            return await running.value
        }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < Self.minimumInterval {
            return .noChange
        }
        let task = Task { await self.performRun(reason: reason) }
        running = task
        let outcome = await task.value
        running = nil
        lastRun = Date()
        return outcome
    }

    private func performRun(reason: String) async -> Outcome {
        let store = SubscriptionStore.shared
        var refreshed = 0
        var failed = 0

        for id in store.subscriptions.map(\.id) {
            // Re-read each time: an earlier refresh or a sync may have replaced it.
            guard let subscription = store.subscriptions.first(where: { $0.id == id }) else { continue }
            let entry = pushStore.entry(for: id)
            let now = Date()

            var serverRev: Int?
            if !SubscriptionRefreshPolicy.isStale(lastUpdate: subscription.lastUpdate, now: now),
               let revURL = entry?.info.revURL {
                serverRev = await fetchRevision(revURL)
            }
            guard SubscriptionRefreshPolicy.shouldRefresh(
                lastUpdate: subscription.lastUpdate, now: now,
                appliedRev: entry?.info.rev, serverRev: serverRev
            ) else { continue }

            do {
                try await store.refresh(subscription)
                refreshed += 1
                logger.info("[\(reason)] Refreshed \(subscription.name) (server rev \(serverRev.map(String.init) ?? "-"))")
            } catch {
                failed += 1
                logger.warning("[\(reason)] Refresh of \(subscription.name) failed: \(error.localizedDescription)")
            }
        }

        await registerTokenEverywhere()

        if refreshed > 0 { return .refreshed }
        return failed > 0 ? .failed : .noChange
    }

    private func fetchRevision(_ url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await SubscriptionFetcher.send(request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else {
            return nil
        }
        return SubscriptionPushInfo.parseRevision(data)
    }

    // MARK: - Hooks from SubscriptionStore

    /// After a successful fetch: the `push` block's revision becomes the applied one.
    /// A fetch without the block (the `/turn` request failed, or a foreign server) keeps
    /// what is on file — a transient failure must not forget the registration.
    func subscriptionFetched(_ id: UUID, push: SubscriptionPushInfo?) {
        guard let push else { return }
        pushStore.setInfo(push, for: id)
        Task { await self.registerTokenEverywhere() }
    }

    /// Best-effort: tell the server to forget this device's token for the subscription.
    func subscriptionDeleted(_ id: UUID) {
        guard let entry = pushStore.remove(id),
              let token = entry.registeredToken,
              let url = entry.registeredURL else { return }
        Task {
            _ = await Self.sendToken(token, to: url, method: "DELETE")
        }
    }

    // MARK: - APNs token

    func deviceTokenReceived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        pushStore.setDeviceToken(hex)
        Task { await self.registerTokenEverywhere() }
    }

    /// Sends the token to every subscription that published a register URL and has not
    /// accepted this token at that URL yet. Only server-provided URLs are ever used.
    func registerTokenEverywhere() async {
        guard let token = pushStore.deviceToken else { return }
        for (id, entry) in pushStore.allEntries() where entry.needsRegistration(of: token) {
            let url = entry.info.apnsRegisterURL
            if await Self.sendToken(token, to: url, method: "POST") {
                pushStore.markRegistered(token: token, url: url, for: id)
                logger.info("Registered push token with \(url.host ?? "?")")
            }
        }
    }

    nonisolated static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    nonisolated private static func sendToken(_ token: String, to url: URL, method: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["token": token]
        if method == "POST" { body["env"] = apnsEnvironment }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await SubscriptionFetcher.send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                logger.warning("Push token \(method) to \(url.host ?? "?") answered \(status)")
            }
            return (200...299).contains(status)
        } catch {
            logger.warning("Push token \(method) to \(url.host ?? "?") failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Silent push

    /// `true` when the remote notification is ours (`anywhere` key) rather than, say, iCloud's.
    nonisolated static func isRefreshPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = userInfo["anywhere"] as? [String: Any] else { return false }
        return (payload["action"] as? String) == "refresh_subscription"
    }
}
