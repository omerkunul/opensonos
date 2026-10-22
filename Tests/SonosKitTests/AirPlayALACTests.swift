#if canImport(AudioToolbox)
import Foundation
import Testing
@testable import SonosKit

// SDP fmtp order as `SDP` collects it:
// [payloadType, frameLength, version, bitDepth, pb, mb, kb, channels, maxRun, maxFrameBytes, avgBitRate, sampleRate]
private let fmtp = [96, 352, 0, 16, 40, 10, 14, 2, 255, 0, 0, 44_100]

@Test func alacCookieHasExpectedLayout() throws {
    let cookie = ALACDecoder.cookie(fmtp: fmtp)
    #expect(cookie.count == 24)
    let b = [UInt8](cookie)
    // frameLength (be32) == 352
    #expect(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) == 352)
    #expect(b[5] == 16)   // bitDepth
    #expect(b[9] == 2)    // channels
    // sampleRate (be32, last four bytes) == 44100
    #expect(UInt32(b[20]) << 24 | UInt32(b[21]) << 16 | UInt32(b[22]) << 8 | UInt32(b[23]) == 44_100)
}

@Test func alacDecoderInitialisesFromFmtp() throws {
    // Validates the whole AudioConverter + magic-cookie configuration without a live sender.
    let decoder = try #require(ALACDecoder(fmtp: fmtp, sampleRate: 44_100))
    #expect(decoder.frameLength == 352)
    #expect(decoder.channels == 2)
}

@Test func alacDecoderRejectsShortFmtp() {
    #expect(ALACDecoder(fmtp: [96, 352, 0], sampleRate: 44_100) == nil)
}
#endif
