import Foundation
import Testing
@testable import SonosKit

@Test func wavHeaderDescribesPCM() {
    let h = WAV.header(sampleRate: 48_000, channels: 2)
    #expect(h.count == 44)
    #expect(String(decoding: h.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: h[8..<16], as: UTF8.self) == "WAVEfmt ")
    func u32(_ at: Int) -> UInt32 { h[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    #expect(u32(24) == 48_000)
    #expect(u32(28) == 192_000)
}

@Test func routesStreamRequests() {
    #expect(AudioServer.route("GET /opensonos/mac.wav HTTP/1.1\r\nHost: x\r\n\r\n") == .stream(.wav))
    #expect(AudioServer.route("HEAD /opensonos/mac.wav HTTP/1.1\r\n\r\n") == .head(.wav))
    #expect(AudioServer.route("GET /opensonos/mac.mp3 HTTP/1.1\r\nHost: x\r\n\r\n") == .stream(.mp3))
    #expect(AudioServer.route("HEAD /opensonos/mac.mp3 HTTP/1.1\r\n\r\n") == .head(.mp3))
    #expect(AudioServer.route("GET /other HTTP/1.1\r\n\r\n") == .notFound)
}

/// The encoder turns PCM into real MP3 frames (0xFFE sync) and consumes 1152 samples/channel/pass.
@Test func mp3EncoderProducesFrames() throws {
    let enc = try MP3Encoder(sampleRate: 48_000, channels: 2)
    // One second of a quiet 440 Hz tone, interleaved stereo 16-bit LE.
    var pcm = Data()
    for i in 0..<48_000 {
        let v = Int16(truncatingIfNeeded: Int(2_000 * sin(2 * Double.pi * 440 * Double(i) / 48_000)))
        for _ in 0..<2 { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
    }
    var out = enc.encode(pcm)
    out.append(enc.flush())
    #expect(out.count > 0)
    // First MP3 frame sync: 11 set bits (0xFF, then top 3 bits of the next byte).
    #expect(out[0] == 0xFF)
    #expect(out[1] & 0xE0 == 0xE0)
}

/// An unsupported sample rate is rejected rather than producing garbage.
@Test func mp3EncoderRejectsUnsupportedRate() {
    #expect(throws: (any Error).self) { _ = try MP3Encoder(sampleRate: 12_345, channels: 2) }
}

/// Gen-1 hardware (swGen "1" or a PLAY:5 S5) is flagged for the MP3 path; modern players aren't.
@Test func detectsLegacyStreamers() {
    var gen1 = Device(uuid: "a", room: "Kitchen", ip: "10.0.0.63"); gen1.swGen = "1"
    var byModel = Device(uuid: "b", room: "Den", ip: "10.0.0.64"); byModel.modelNumber = "S5"
    var modern = Device(uuid: "c", room: "Living Room", ip: "10.0.0.62"); modern.swGen = "2"; modern.modelNumber = "S14"
    #expect(gen1.isLegacyStreamer)
    #expect(byModel.isLegacyStreamer)
    #expect(!modern.isLegacyStreamer)
}

@Test func recognisesMacStream() {
    let np = NowPlaying.parse(state: "PLAYING", mediaURI: "http://10.0.0.20:51400/opensonos/mac.wav", mediaMeta: "",
                              trackURI: "", trackMeta: "")
    #expect(np.source == .mac && np.title == "Mac")
}

/// The gen-1 MP3 stream (x-rincon-mp3radio) must read as .mac, not generic .radio — otherwise
/// the room-watcher mistakes our own stream for another source and tears the capture down.
@Test func recognisesMacMP3Stream() {
    let np = NowPlaying.parse(state: "PLAYING",
                              mediaURI: "x-rincon-mp3radio://http://10.0.0.20:51400/opensonos/mac.mp3",
                              mediaMeta: "", trackURI: "", trackMeta: "")
    #expect(np.source == .mac)
}

/// The server on loopback only: nothing is sent to a speaker.
@Test func serverStreamsHeaderAndAudio() async throws {
    let server = AudioServer()
    let port = try await server.start(sampleRate: 44_100, channels: 2, preferred: 0)
    defer { server.stop() }
    let url = URL(string: "http://127.0.0.1:\(port)\(AudioServer.path)")!
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
    server.send(Data(repeating: 7, count: 64))
    var got = Data()
    for try await b in bytes {
        got.append(b)
        if got.count >= 44 + 64 { break }
    }
    #expect(got.prefix(4) == Data("RIFF".utf8))
    #expect(got[44] == 7)
}
