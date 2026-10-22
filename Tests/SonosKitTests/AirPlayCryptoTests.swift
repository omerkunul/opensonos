import CommonCrypto
import Foundation
import Testing
@testable import SonosKit

@Test func appleResponseIsDeterministicAndFullWidth() throws {
    #expect(AirPlayCrypto.isAvailable)
    let challenge = Data((0..<16).map { UInt8($0) })
    let ip = Data([192, 168, 1, 23])
    let mac = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])

    let a = try #require(AirPlayCrypto.appleResponse(challenge: challenge, ip: ip, mac: mac))
    let b = try #require(AirPlayCrypto.appleResponse(challenge: challenge, ip: ip, mac: mac))
    #expect(a == b)                          // deterministic (raw PKCS#1 v1.5, no salt)
    #expect(!a.contains("="))                // padding stripped, as senders expect

    // Re-pad and decode: a 2048-bit RSA signature is exactly 256 bytes.
    var padded = a
    while padded.count % 4 != 0 { padded.append("=") }
    let sig = try #require(Data(base64Encoded: padded))
    #expect(sig.count == 256)
}

@Test func aesAudioDecryptsWholeBlocksAndKeepsTrailer() {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let plaintext = Data((0..<53).map { UInt8(truncatingIfNeeded: $0 * 7) })   // 3 blocks + 5 trailing bytes

    // AirPlay encrypts only whole 16-byte blocks; the trailing 5 bytes travel in the clear.
    let whole = plaintext.count - (plaintext.count % 16)
    let encrypted = cbcEncrypt(plaintext.prefix(whole), key: key, iv: iv)
    let onWire = encrypted + plaintext.suffix(plaintext.count - whole)

    let decrypted = AirPlayCrypto.decryptAudio(onWire, key: key, iv: iv)
    #expect(decrypted == plaintext)
}

@Test func aesDecryptLeavesShortOrMiskeyedDataUntouched() {
    let key = Data(count: 16)
    let iv = Data(count: 16)
    let short = Data([1, 2, 3])                       // < one block
    #expect(AirPlayCrypto.decryptAudio(short, key: key, iv: iv) == short)
    let block = Data(count: 16)
    #expect(AirPlayCrypto.decryptAudio(block, key: Data(count: 8), iv: iv) == block)  // bad key size
}

/// CBC-encrypts whole blocks with no padding, mirroring what an AirPlay sender transmits.
private func cbcEncrypt(_ data: Data, key: Data, iv: Data) -> Data {
    let capacity = data.count
    var out = Data(count: capacity)
    var moved = 0
    _ = out.withUnsafeMutableBytes { outPtr in
        data.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(0),
                            keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                            inPtr.baseAddress, data.count, outPtr.baseAddress, capacity, &moved)
                }
            }
        }
    }
    out.removeSubrange(moved..<out.count)
    return out
}
