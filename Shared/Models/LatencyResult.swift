//
//  LatencyResult.swift
//  Anywhere
//
//  Created by NodePassProject on 5/9/26.
//

import Foundation

nonisolated enum LatencyResult: Sendable, Hashable {
    case testing
    case success(Int)  // milliseconds
    case failed
    case insecure
    /// The REALITY server refused us (spliced to its donor site) — usually a client
    /// too old for the server's Xray, not a network problem.
    case rejected
}
