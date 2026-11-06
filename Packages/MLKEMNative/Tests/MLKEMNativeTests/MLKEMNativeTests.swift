//
//  MLKEMNativeTests.swift
//  MLKEMNative
//
//  Known-answer vectors are the ML-KEM-768 block of mlkem-native v2.0.0
//  examples/monolithic_build/expected_test_vectors.h (pk/sk/ct as SHA-256).
//  The CryptoKit cases cross-check against Apple's independent ML-KEM.
//

import CryptoKit
import Foundation
import MLKEMNative
import Testing

private func hex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func sha256(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

private enum KAT {
    static let d = hex("934d60b35624d740b30a7f227af2ae7c678e4e04e13c5f509eade2b79aea77e2")
    static let z = hex("3e2a2ea6c9c476fc4937b013c993a793d6c0ab9960695ba838f649da539ca3d0")
    static let m = hex("934d60b35624d740b30a7f227af2ae7c678e4e04e13c5f509eade2b79aea77e2")
    static let pkSHA256 = "c45a699a9efcb1a799578ce95f24b063b0b9ddc0879afdb3967fd9e1e3e8c247"
    static let skSHA256 = "1dc4ab0188bfd90b41bbd91884e40a41ccd0f46e5d3754b615373c9656f6af39"
    static let ctSHA256 = "0b99b2af81971943e4ef6e6f17f42be4f3caa9fea18da0f63df1d43639a74743"
    static let ss = hex("0b1b32be26247cbcbe0916f8b0b729699c32a96d51efa4a4cd5b289239c8207e")
}

struct MLKEMNativeTests {

    @Test func knownAnswerKeyGenEncapsDecaps() throws {
        let key = try MLKEM768Native.PrivateKey(seed: KAT.d + KAT.z)
        #expect(key.publicKey.count == 1184)
        #expect(sha256(key.publicKey) == KAT.pkSHA256)

        let (ct, ss) = try MLKEM768Native.encapsulate(to: key.publicKey, randomness: KAT.m)
        #expect(sha256(ct) == KAT.ctSHA256)
        #expect(ss == KAT.ss)
        #expect(try key.decapsulate(ct) == KAT.ss)
    }

    @Test func randomRoundTrip() throws {
        let key = try MLKEM768Native.PrivateKey()
        let (ct, ss) = try MLKEM768Native.encapsulate(to: key.publicKey)
        #expect(try key.decapsulate(ct) == ss)
        #expect(try MLKEM768Native.PrivateKey().publicKey != key.publicKey)
    }

    @Test func rejectsWrongSizes() {
        #expect(throws: MLKEM768Native.Failure.self) { try MLKEM768Native.PrivateKey(seed: Data(count: 63)) }
        #expect(throws: MLKEM768Native.Failure.self) { try MLKEM768Native.encapsulate(to: Data(count: 10)) }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    @Test func sameSeedSamePublicKeyAsCryptoKit() throws {
        let seed = KAT.d + KAT.z
        let ours = try MLKEM768Native.PrivateKey(seed: seed)
        let apple = try CryptoKit.MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
        #expect(apple.publicKey.rawRepresentation == ours.publicKey)
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    @Test func cryptoKitEncapsulatesOursDecapsulates() throws {
        let ours = try MLKEM768Native.PrivateKey()
        let applePK = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: ours.publicKey)
        let result = try applePK.encapsulate()
        let ss = try ours.decapsulate(result.encapsulated)
        #expect(ss == result.sharedSecret.withUnsafeBytes { Data($0) })
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    @Test func oursEncapsulatesCryptoKitDecapsulates() throws {
        let apple = try CryptoKit.MLKEM768.PrivateKey()
        let (ct, ss) = try MLKEM768Native.encapsulate(to: apple.publicKey.rawRepresentation)
        let appleSS = try apple.decapsulate(ct)
        #expect(appleSS.withUnsafeBytes { Data($0) } == ss)
    }
}
