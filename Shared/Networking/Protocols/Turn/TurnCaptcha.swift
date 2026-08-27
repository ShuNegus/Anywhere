//
//  TurnCaptcha.swift
//  Anywhere
//

import Foundation
import Network

/// The vk-turn manual captcha solver hosts a small HTTP server on a fixed loopback port
/// inside the tunnel process. The app reaches it over loopback to show the page in a
/// web view; the tunnel never captures 127.0.0.0/8, so this works across the process
/// boundary without any IPC.
nonisolated enum TurnCaptcha {
    static let host = "127.0.0.1"
    static let port: UInt16 = 8765
    static var url: URL { URL(string: "http://\(host):\(port)/")! }

    /// Identifier of the local notification the tunnel posts when a captcha appears
    /// while the app is backgrounded. Shared so the app can route a tap on it.
    static let notificationID = "turn-captcha"

    /// Pure TCP reachability check — no HTTP request is made, so probing has no side
    /// effect on the captcha flow. `true` means a captcha is waiting to be solved.
    static func probe(timeout: TimeInterval = 1) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let resolver = ProbeResolver(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resolver.finish(true, connection)
                case .failed, .cancelled: resolver.finish(false, connection)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resolver.finish(false, connection)
            }
        }
    }
}

/// Resumes the probe continuation exactly once, whichever of ready/failed/timeout wins.
nonisolated private final class ProbeResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool, _ connection: NWConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}
