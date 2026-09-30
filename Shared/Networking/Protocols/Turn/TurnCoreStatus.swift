//
//  TurnCoreStatus.swift
//  Anywhere
//

import Foundation

/// Snapshot of one Go dialer, decoded from `clientcore.Status` (`Dialer.StatusJSON()`).
///
/// Unlike the single `phase`, it keeps apart what the UI must not conflate: whether the
/// tunnel can carry traffic at all (`usable`), how full the pool is (`sessions` of
/// `target`), and what the credential fetch is doing. The core fetches another VK
/// credential set — and so possibly another captcha — only when the relay refuses the
/// current one (20 peers per set), so a captcha can be pending while the tunnel already
/// works.
///
/// Declared unconditionally so the app target, which does not link `Turn.xcframework`,
/// can decode it from the extension's IPC reply.
nonisolated struct TurnCoreStatus: Codable, Hashable, Sendable {

    /// What the pool's credential fetch is doing.
    nonisolated enum FetchState: String, Codable, Hashable, Sendable {
        case idle
        /// VK login in progress.
        case fetching
        /// A captcha is being solved automatically.
        case captchaAuto = "captcha_auto"
        /// A captcha waits for the user.
        case captchaWait = "captcha_wait"
        /// Sessions wait for room and the next fetch is held back after a failure.
        case backoff
        /// A state this build does not know (a newer core).
        case unknown

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = FetchState(rawValue: raw) ?? .unknown
        }

        var isCaptcha: Bool { self == .captchaAuto || self == .captchaWait }

        /// How much the UI should care, most urgent first; used to combine pools.
        fileprivate var urgency: Int {
            switch self {
            case .captchaWait: return 5
            case .captchaAuto: return 4
            case .fetching:    return 3
            case .backoff:     return 2
            case .unknown:     return 1
            case .idle:        return 0
            }
        }
    }

    nonisolated struct Fetch: Codable, Hashable, Sendable {
        let state: FetchState
        /// Credential set being fetched, -1 when none is.
        let setId: Int
        let backoffMs: Int?
        /// Sessions waiting for a slot.
        let waiting: Int
    }

    nonisolated struct CredentialSet: Codable, Hashable, Sendable, Identifiable {
        let id: Int
        /// `filling`, `full` or `retired`.
        let state: String
        let active: Int
        let pending: Int
        /// Learned capacity once the relay said the set is full; 0 before.
        let capacity: Int
    }

    let version: Int
    let usable: Bool
    let sessions: Int
    let target: Int
    /// Legacy single-step phase (`TurnPhase` raw value).
    let phase: Int
    let fetch: Fetch
    let setsObtained: Int
    let setsRetired: Int
    let captchas: Int
    let sets: [CredentialSet]

    /// The format version this build understands. A higher one from a newer core is
    /// still decoded — fields are only ever added within a version — but a bump means a
    /// field changed meaning, so it is not trusted.
    static let supportedVersion = 1

    /// Decodes the core's JSON (snake_case). `nil` for an empty or unknown payload.
    static func decode(coreJSON: String) -> TurnCoreStatus? {
        guard !coreJSON.isEmpty, let data = coreJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let status = try? decoder.decode(TurnCoreStatus.self, from: data),
              status.version == supportedVersion else { return nil }
        return status
    }
}

/// The bypass pools of all relays folded into what the UI shows. Normally there is one
/// pool (the selected server); combining keeps it honest when more than one is up.
/// `usable` means *any* pool carries traffic — with a stale second pool alive that can
/// hide a stuck one, which the single-pool normal case does not have.
nonisolated struct TurnPoolSummary: Hashable, Sendable {
    /// At least one pool carries traffic.
    let usable: Bool
    let sessions: Int
    let target: Int
    /// The most urgent fetch state across the pools.
    let fetch: TurnCoreStatus.FetchState
    /// Fetches that hit a captcha, over the pools' lifetime.
    let captchas: Int
    /// Credential sets obtained, over the pools' lifetime; a rise means a login finished.
    let setsObtained: Int

    init(usable: Bool, sessions: Int, target: Int, fetch: TurnCoreStatus.FetchState,
         captchas: Int, setsObtained: Int) {
        self.usable = usable
        self.sessions = sessions
        self.target = target
        self.fetch = fetch
        self.captchas = captchas
        self.setsObtained = setsObtained
    }

    /// `nil` when no pool reports a status (none running, or an older extension).
    init?(combining statuses: [TurnCoreStatus]) {
        guard !statuses.isEmpty else { return nil }
        usable = statuses.contains(where: \.usable)
        sessions = statuses.reduce(0) { $0 + $1.sessions }
        target = statuses.reduce(0) { $0 + $1.target }
        fetch = statuses.map(\.fetch.state).max { $0.urgency < $1.urgency } ?? .idle
        captchas = statuses.reduce(0) { $0 + $1.captchas }
        setsObtained = statuses.reduce(0) { $0 + $1.setsObtained }
    }

    /// The tunnel works and the pool is still being topped up with more credentials.
    var isAddingPeers: Bool {
        usable && sessions < target && fetch != .idle
    }

    /// The tunnel works, but more peers need the user to solve a captcha.
    var needsCaptchaForMorePeers: Bool {
        usable && fetch == .captchaWait
    }
}
