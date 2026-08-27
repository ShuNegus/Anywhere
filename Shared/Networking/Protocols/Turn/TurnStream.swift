//
//  TurnStream.swift
//  Anywhere
//

import Foundation

#if canImport(Turn)
import Turn
import Synchronization

/// A single multiplexed connection through the TURN tunnel.
///
/// The Go side is blocking, so every call hops onto a dedicated dispatch queue rather
/// than parking a cooperative thread. Reads and writes get separate queues so a stalled
/// read never delays a write on the same stream.
nonisolated final class TurnStream: Sendable {

    /// Crossing the gomobile boundary costs a bridge hop and a copy each way, so reads
    /// are asked for in large chunks.
    static let readChunkSize = 32 * 1024

    nonisolated(unsafe) private let stream: AnywhereStream
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let closed = Mutex(false)

    var isOpen: Bool { !closed.withLock { $0 } }

    init(stream: AnywhereStream, label: String) {
        self.stream = stream
        self.readQueue = DispatchQueue(label: "\(AWCore.Identifier.bundle).turn.read.\(label)")
        self.writeQueue = DispatchQueue(label: "\(AWCore.Identifier.bundle).turn.write.\(label)")
    }

    /// Reads one chunk. `nil` means the peer closed the stream.
    func read() async throws -> Data? {
        if closed.withLock({ $0 }) { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [stream] in
                do {
                    continuation.resume(returning: try stream.read(Self.readChunkSize))
                } catch {
                    // Go reports end-of-stream as an error; this transport reports it as nil.
                    if TurnError.isEndOfStream(error) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: TurnError.io(error))
                    }
                }
            }
        }
    }

    /// Writes the whole buffer.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if closed.withLock({ $0 }) { throw TurnError.streamClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [stream] in
                do {
                    var written: Int = 0
                    try stream.write(data, ret0_: &written)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: TurnError.io(error))
                }
            }
        }
    }

    func close() {
        let wasOpen = closed.withLock { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        // Close off the caller's thread: it unblocks a pending read inside Go.
        readQueue.async { [stream] in try? stream.close() }
    }
}
#endif
