//
//  SubscriptionBackgroundRefresh.swift
//  Anywhere
//

import BackgroundTasks
import Foundation

nonisolated private let logger = AnywhereLogger(category: "SubscriptionBackgroundRefresh")

/// `BGAppRefreshTask` running the same check as app activation
/// (`SubscriptionAutoRefresher`). iOS decides when — or whether — it actually runs;
/// activation and the silent push cover the rest.
enum SubscriptionBackgroundRefresh {

    static let taskIdentifier = "su.smd.Anywhere.subscription-refresh"
    private static let interval: TimeInterval = 60 * 60

    /// Must be called before the app finishes launching.
    ///
    /// The launch handler goes on the main queue: the app target is MainActor by default,
    /// so a handler called on BGTaskScheduler's own background queue would break that
    /// isolation.
    static func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
        if !registered {
            logger.warning("Background refresh task was not registered")
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and denied Background App Refresh land here; activation still works.
            logger.debug("Background refresh not scheduled: \(error.localizedDescription)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let outcome = await SubscriptionAutoRefresher.shared.run(reason: "background", force: true)
            task.setTaskCompleted(success: outcome != .failed)
        }
        task.expirationHandler = { work.cancel() }
    }
}
