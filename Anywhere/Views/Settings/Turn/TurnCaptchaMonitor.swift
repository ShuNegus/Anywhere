//
//  TurnCaptchaMonitor.swift
//  Anywhere
//

import Foundation
import Observation

/// Polls the tunnel process's loopback captcha server while TURN is on, and drives the
/// captcha sheet.
///
/// Polling is unconditional on the captcha mode: the local server only appears when
/// manual solving is actually needed — either the user chose it, or the automatic solver
/// failed and the core escalated.
@MainActor
@Observable
final class TurnCaptchaMonitor {

    static let shared = TurnCaptchaMonitor()

    private static let pollInterval = Duration.milliseconds(1500)

    /// True while a captcha is waiting and the user has not closed the sheet.
    private(set) var showCaptcha = false

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set when the user closes the sheet; cleared when the server cycles, so a fresh
    /// captcha re-opens it but a dismissed one stays closed.
    @ObservationIgnored private var suppressed = false

    private init() {}

    func setActive(_ active: Bool) {
        if active {
            guard task == nil else { return }
            task = Task { [weak self] in await self?.loop() }
        } else {
            task?.cancel()
            task = nil
            suppressed = false
            showCaptcha = false
        }
    }

    /// The user closed the sheet: leave it closed until a new captcha appears.
    func userDismissed() {
        suppressed = true
        showCaptcha = false
    }

    /// Re-arms the sheet after the user asks for it explicitly.
    func requestShow() {
        suppressed = false
        showCaptcha = true
    }

    private func loop() async {
        while !Task.isCancelled {
            if AWCore.getTurnFeatureEnabled(), AWCore.getTurnEnabled() {
                if await TurnCaptcha.probe() {
                    if !suppressed { showCaptcha = true }
                } else {
                    // Server gone: the captcha was solved or abandoned.
                    suppressed = false
                    showCaptcha = false
                }
            } else if showCaptcha {
                showCaptcha = false
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
