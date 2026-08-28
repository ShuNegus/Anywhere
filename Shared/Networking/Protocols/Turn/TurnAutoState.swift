//
//  TurnAutoState.swift
//  Anywhere
//
//  Created by NodePassProject on 8/28/26.
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TurnAutoState")

/// The route auto mode has settled on, shared by everything that has to honour it.
///
/// Deliberately free of any `Turn` framework dependency: the app process reads it to
/// draw the connection graph, and the extension reads it on every flow.
nonisolated final class TurnAutoState: Sendable {

    static let shared = TurnAutoState()

    enum Decision: String, Sendable {
        /// No probe has finished yet — flows wait rather than guess.
        case undecided
        case direct
        case turn
        /// Nothing was reachable; treated as "no bypass" so flows are not held hostage.
        case offline
    }

    private struct State {
        var decision: Decision = .undecided
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    private init() {}

    var decision: Decision { state.withLock { $0.decision } }

    /// Records a verdict. `.turn` is sticky for the life of the tunnel: once flows are
    /// riding the relay, flipping back would strand every stream already on it, and the
    /// network that needed the bypass is the one worth staying pessimistic about.
    func setDecision(_ new: Decision) {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            guard state.decision != .turn else { return [] }
            state.decision = new
            guard new != .undecided else { return [] }
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            return pending
        }
        if !waiters.isEmpty { logger.debug("[TURN auto] \(new.rawValue), releasing \(waiters.count) flow(s)") }
        for waiter in waiters { waiter.resume() }
    }

    /// Blocks until a verdict exists, so the first flows of a session do not race the
    /// probe and dial directly out of a censored network. Returns at once when the mode
    /// is not `.auto` or a decision is already in hand; the timeout is the safety net for
    /// a probe that never lands.
    func waitForDecision(timeout: Duration = .seconds(3)) async {
        guard AWCore.getTurnMode() == .auto else { return }
        guard state.withLock({ $0.decision }) == .undecided else { return }

        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.release(id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyDecided: Bool = state.withLock { state in
                guard state.decision == .undecided else { return true }
                state.waiters[id] = continuation
                return false
            }
            if alreadyDecided { continuation.resume() }
        }
        timer.cancel()
    }

    /// Back to square one for the next tunnel session; nobody is left waiting.
    func reset() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.decision = .undecided
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    private func release(_ id: UUID) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        waiter?.resume()
    }
}
