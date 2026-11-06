//
//  MLKEM768Shim.swift
//  Anywhere
//
//  ML-KEM-768 for the X25519MLKEM768 key share on every supported iOS.
//  iOS 26+ uses CryptoKit; earlier versions use the vendored mlkem-native
//  (Packages/MLKEMNative). Kept in its own file so upstream merges only touch
//  the few call sites that construct and use the key.
//

import CryptoKit
import Foundation
import MLKEMNative

nonisolated enum MLKEM768Shim {
    /// Always true: one of the two implementations is present on every OS we ship to.
    static let isAvailable = true

    /// Test hook: forces the vendored implementation even where CryptoKit has ML-KEM.
    nonisolated(unsafe) static var forceNative = false

    /// A fresh decapsulation key, or nil if key generation failed.
    static func makePrivateKey() -> MLKEM768ShimKey? {
        if !forceNative, #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            guard let key = try? CryptoKit.MLKEM768.PrivateKey() else { return nil }
            return MLKEM768ShimKey(system: key)
        }
        guard let key = try? MLKEM768Native.PrivateKey() else { return nil }
        return MLKEM768ShimKey(native: key)
    }
}

nonisolated struct MLKEM768ShimKey: @unchecked Sendable {
    enum Backend { case system, native }

    let backend: Backend
    /// Encapsulation key, 1184 bytes.
    let publicKeyRaw: Data
    private let decapsulateImpl: (Data) throws -> Data

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    fileprivate init(system key: CryptoKit.MLKEM768.PrivateKey) {
        backend = .system
        publicKeyRaw = Data(key.publicKey.rawRepresentation)
        decapsulateImpl = { ciphertext in
            try key.decapsulate(ciphertext).withUnsafeBytes { Data($0) }
        }
    }

    fileprivate init(native key: MLKEM768Native.PrivateKey) {
        backend = .native
        publicKeyRaw = key.publicKey
        decapsulateImpl = { ciphertext in try key.decapsulate(ciphertext) }
    }

    /// Shared secret (32 bytes) for a 1088-byte ciphertext.
    func decapsulate(_ ciphertext: Data) throws -> Data {
        try decapsulateImpl(ciphertext)
    }
}
