//
//  MLKEM768ShimTests.swift
//  Anywhere
//
//  The shim picks CryptoKit on iOS 26+ and the vendored mlkem-native
//  otherwise; both must interoperate with CryptoKit byte for byte.
//

import CryptoKit
import Foundation
import Testing
@testable import Anywhere

@Suite(.serialized)
struct MLKEM768ShimTests {

    @Test func usesSystemImplementationWhereAvailable() throws {
        MLKEM768Shim.forceNative = false
        let key = try #require(MLKEM768Shim.makePrivateKey())
        if #available(iOS 26.0, *) {
            #expect(key.backend == .system)
        } else {
            #expect(key.backend == .native)
        }
        #expect(key.publicKeyRaw.count == 1184)
    }

    @Test func nativeKeyRoundTripsWithCryptoKit() throws {
        MLKEM768Shim.forceNative = true
        defer { MLKEM768Shim.forceNative = false }

        let key = try #require(MLKEM768Shim.makePrivateKey())
        #expect(key.backend == .native)
        #expect(key.publicKeyRaw.count == 1184)

        guard #available(iOS 26.0, *) else { return }
        let peer = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: key.publicKeyRaw)
        let result = try peer.encapsulate()
        let shared = try key.decapsulate(result.encapsulated)
        #expect(shared.count == 32)
        #expect(shared == result.sharedSecret.withUnsafeBytes { Data($0) })
    }

    @Test func systemKeyRoundTripsWithCryptoKit() throws {
        guard #available(iOS 26.0, *) else { return }
        MLKEM768Shim.forceNative = false
        let key = try #require(MLKEM768Shim.makePrivateKey())
        let peer = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: key.publicKeyRaw)
        let result = try peer.encapsulate()
        #expect(try key.decapsulate(result.encapsulated) == result.sharedSecret.withUnsafeBytes { Data($0) })
    }

    @Test func wrongCiphertextLengthThrows() throws {
        MLKEM768Shim.forceNative = true
        defer { MLKEM768Shim.forceNative = false }
        let key = try #require(MLKEM768Shim.makePrivateKey())
        #expect(throws: (any Error).self) { try key.decapsulate(Data(count: 100)) }
    }

    /// With ML-KEM available on every OS, imported fingerprints keep their
    /// post-quantum variant instead of falling back to the pre-PQ one.
    @Test func importedFingerprintsKeepPostQuantum() {
        #expect(MLKEM768Shim.isAvailable)
        #expect(TLSFingerprint.firefox148.supportedOnThisOS == .firefox148)
        #expect(TLSFingerprint.chrome133.supportedOnThisOS == .chrome133)
        #expect(TLSFingerprint.firefox148.offersPostQuantumKeyShare)
    }
}
