import Foundation
import Testing
@testable import SonosKit

@Test func rtspParsesRequestAndEchoesCSeq() throws {
    let raw = Data("OPTIONS * RTSP/1.0\r\nCSeq: 7\r\nApple-Challenge: abc\r\n\r\n".utf8)
    let (message, consumed) = try #require(RTSPMessage.parse(raw))
    #expect(message.method == "OPTIONS")
    #expect(message.uri == "*")
    #expect(message.headers["cseq"] == "7")
    #expect(message.headers["apple-challenge"] == "abc")
    #expect(consumed == raw.count)

    let response = RTSPMessage.response(cseq: message.headers["cseq"] ?? "0",
                                        headers: ["Public": "OPTIONS"])
    let text = String(decoding: response, as: UTF8.self)
    #expect(text.hasPrefix("RTSP/1.0 200 OK\r\n"))
    #expect(text.contains("CSeq: 7\r\n"))
    #expect(text.contains("Public: OPTIONS\r\n"))
}

@Test func rtspParsesBodyByContentLength() throws {
    let body = "v=0\r\nm=audio 0 RTP/AVP 96\r\n"
    let raw = Data("ANNOUNCE rtsp://x RTSP/1.0\r\nCSeq: 2\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    let (message, consumed) = try #require(RTSPMessage.parse(raw))
    #expect(message.method == "ANNOUNCE")
    #expect(message.bodyText == body)
    #expect(consumed == raw.count)
}

@Test func rtspWaitsForIncompleteMessage() {
    let partial = Data("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n".utf8)   // no blank-line terminator yet
    #expect(RTSPMessage.parse(partial) == nil)
}

@Test func sdpReadsAlacFormat() throws {
    let sdp = """
    v=0\r
    o=iTunes 1 0 IN IP4 10.0.0.1\r
    m=audio 0 RTP/AVP 96\r
    a=rtpmap:96 AppleLossless\r
    a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r
    a=aesiv:AAAAAAAAAAAAAAAAAAAAAA\r
    """
    let format = try #require(SDP.audioFormat(from: sdp))
    #expect(format.payloadType == 96)
    #expect(format.sampleRate == 44_100)   // from the ALAC fmtp cookie
    #expect(format.channels == 2)
    #expect(format.aesIV != nil)
}

@Test func deviceIDIsStableTwelveHexPerRoom() {
    let a = AirPlayStation.deviceID(for: "RINCON_KITCHEN01400")
    let b = AirPlayStation.deviceID(for: "RINCON_KITCHEN01400")
    let c = AirPlayStation.deviceID(for: "RINCON_LIVINGROOM01400")
    #expect(a == b)
    #expect(a != c)
    #expect(a.count == 12)
    #expect(a.allSatisfy { $0.isHexDigit })
}

@Test func txtRecordAdvertisesAlacWithRSA() {
    let txt = AirPlayStation.txtRecord(deviceID: "AABBCCDDEEFF")
    #expect(txt["et"] == "0,1")     // plain + RSA/AES, iOS needs the latter
    #expect(txt["ek"] == "1")
    #expect(txt["cn"] == "0,1")     // PCM + ALAC
    #expect(txt["sr"] == "44100")
}
