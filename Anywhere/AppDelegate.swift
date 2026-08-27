//
//  AppDelegate.swift
//  Anywhere
//

import UIKit
import UserNotifications

/// Exists only to route the TURN captcha notification: tapping it has to re-open the
/// captcha sheet, which requires being the `UNUserNotificationCenter` delegate.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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
