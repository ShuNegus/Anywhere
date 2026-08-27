//
//  TurnCaptchaNotifier.swift
//  Anywhere Network Extension
//

import Foundation
import Synchronization
import UserNotifications

/// Runs inside the tunnel process. The vk-turn manual captcha solver hosts a local
/// server on a fixed loopback port while it waits for the user, but the in-app monitor
/// cannot see that while the app is suspended — which is exactly when it matters. So the
/// extension polls the port itself and posts a local notification when a captcha shows
/// up and the app is not frontmost. Tapping it opens the app, whose monitor then puts up
/// the web view.
nonisolated final class TurnCaptchaNotifier: Sendable {
    private static let pollInterval = Duration.milliseconds(1500)

    private let task = Mutex<Task<Void, Never>?>(nil)

    func start() {
        task.withLock { task in
            guard task == nil else { return }
            task = Task { await Self.loop() }
        }
    }

    func stop() {
        let running = task.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        running?.cancel()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [TurnCaptcha.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [TurnCaptcha.notificationID])
    }

    private static func loop() async {
        var wasReachable = false
        while !Task.isCancelled {
            guard AWCore.getTurnFeatureEnabled(), AWCore.getTurnEnabled() else {
                if wasReachable {
                    clearNotification()
                    wasReachable = false
                }
                try? await Task.sleep(for: pollInterval)
                continue
            }

            let reachable = await TurnCaptcha.probe()
            if reachable, !wasReachable {
                if !AWCore.getAppInForeground() {
                    await postNotification()
                }
            } else if !reachable, wasReachable {
                // Server gone: the captcha was solved or abandoned.
                clearNotification()
            }
            wasReachable = reachable

            try? await Task.sleep(for: pollInterval)
        }
    }

    private static func clearNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [TurnCaptcha.notificationID])
    }

    // The string catalog is a member of the extension target too, so lookups resolve
    // against `Bundle.main` — which, inside an appex, is the appex bundle.
    private static func postNotification() async {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "turn.captcha.notification.title",
            defaultValue: "Captcha required"
        )
        content.body = String(
            localized: "turn.captcha.notification.body",
            defaultValue: "Open the app to solve the captcha and connect through TURN."
        )
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: TurnCaptcha.notificationID,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
