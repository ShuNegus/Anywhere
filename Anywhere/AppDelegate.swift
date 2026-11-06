//
//  AppDelegate.swift
//  Anywhere
//

import UIKit
import UserNotifications

nonisolated private let logger = AnywhereLogger(category: "AppDelegate")

/// Routes the TURN captcha notification (tapping it has to re-open the captcha sheet,
/// which requires being the `UNUserNotificationCenter` delegate), and wires up forced
/// subscription refresh: the APNs token, the silent push and the background task.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SubscriptionBackgroundRefresh.register()
        // Silent pushes need no permission prompt, only a token.
        application.registerForRemoteNotifications()
        return true
    }

    // MARK: - Forced subscription refresh

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SubscriptionAutoRefresher.shared.deviceTokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.warning("APNs registration failed: \(error.localizedDescription)")
    }

    /// Silent push from a subscription server asking for a refresh. Anything without our
    /// `anywhere` key (e.g. iCloud) is left alone.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard SubscriptionAutoRefresher.isRefreshPush(userInfo) else { return .noData }
        switch await SubscriptionAutoRefresher.shared.run(reason: "push", force: true) {
        case .refreshed: return .newData
        case .noChange: return .noData
        case .failed: return .failed
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == TurnCaptcha.notificationID else { return }
        await MainActor.run {
            TurnCaptchaMonitor.shared.requestShow()
        }
    }

    /// No banner while the user is already looking at the app — the monitor's sheet is
    /// the right surface, and this also covers a race on the foreground flag.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
