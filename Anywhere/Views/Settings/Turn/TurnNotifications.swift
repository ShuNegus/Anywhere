//
//  TurnNotifications.swift
//  Anywhere
//

import Foundation
import UserNotifications

/// Local-notification permission used to alert about a waiting TURN captcha while the
/// app is backgrounded. Requested from foreground UI so the system prompt actually
/// appears, and only once — a user who declined is not asked again.
enum TurnNotifications {
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}
