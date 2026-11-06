//
//  MLKEMNative.swift
//  MLKEMNative
//
//  Thin Swift wrapper over the vendored mlkem-native (ML-KEM-768, FIPS 203).
//

import CMLKEMNative
import Foundation

public enum MLKEM768Native {
    public static let publicKeyByteCount = 1184
    public static let secretKeyByteCount = 2400
    public static let ciphertextByteCount = 1088
    public static let sharedSecretByteCount = 32

    public enum Failure: Error {
        case invalidInput
        case operationFailed(Int32)
    }

    /// A decapsulation key with its encapsulation (public) key.
    public struct PrivateKey: Sendable {
        public let publicKey: Data
        let secretKey: Data

        /// Fresh key pair from the system CSPRNG.
        public init() throws {
            var pk = [UInt8](repeating: 0, count: publicKeyByteCount)
            var sk = [UInt8](repeating: 0, count: secretKeyByteCount)
            let rc = aw_mlkem768_keypair(&pk, &sk)
            guard rc == 0 else { throw Failure.operationFailed(rc) }
            publicKey = Data(pk)
            secretKey = Data(sk)
        }

        /// Deterministic key pair from the 64-byte seed `d || z` (FIPS 203 KeyGen_internal).
        public init(seed: Data) throws {
            guard seed.count == 64 else { throw Failure.invalidInput }
            var pk = [UInt8](repeating: 0, count: publicKeyByteCount)
            var sk = [UInt8](repeating: 0, count: secretKeyByteCount)
            let coins = [UInt8](seed)
            let rc = aw_mlkem768_keypair_derand(&pk, &sk, coins)
            guard rc == 0 else { throw Failure.operationFailed(rc) }
            publicKey = Data(pk)
            secretKey = Data(sk)
        }

        /// Shared secret (32 bytes) for a 1088-byte ciphertext.
        public func decapsulate(_ ciphertext: Data) throws -> Data {
            guard ciphertext.count == ciphertextByteCount else { throw Failure.invalidInput }
            var ss = [UInt8](repeating: 0, count: sharedSecretByteCount)
            let ct = [UInt8](ciphertext)
            let sk = [UInt8](secretKey)
            let rc = aw_mlkem768_dec(&ss, ct, sk)
            guard rc == 0 else { throw Failure.operationFailed(rc) }
            return Data(ss)
        }
    }

    /// Encapsulates to `publicKey`; `randomness` (32 bytes) makes it deterministic.
    public static func encapsulate(to publicKey: Data, randomness: Data? = nil) throws -> (ciphertext: Data, sharedSecret: Data) {
        guard publicKey.count == publicKeyByteCount else { throw Failure.invalidInput }
        var ct = [UInt8](repeating: 0, count: ciphertextByteCount)
        var ss = [UInt8](repeating: 0, count: sharedSecretByteCount)
        let pk = [UInt8](publicKey)
        let rc: Int32
        if let randomness {
            guard randomness.count == 32 else { throw Failure.invalidInput }
            rc = aw_mlkem768_enc_derand(&ct, &ss, pk, [UInt8](randomness))
        } else {
            rc = aw_mlkem768_enc(&ct, &ss, pk)
        }
        guard rc == 0 else { throw Failure.operationFailed(rc) }
        return (Data(ct), Data(ss))
    }
}
