import CShine
import Foundation

/// Encodes live 16-bit little-endian interleaved PCM into MP3 frames on the fly, using the
/// vendored fixed-point shine encoder. Old gen-1 Sonos players (e.g. the PLAY:5 S5) refuse an
/// endless PCM/WAV stream but will play Streaming MP3 over `x-rincon-mp3radio://`, so the Mac
/// stream is encoded to MP3 for those rooms.
///
/// Not thread-safe: feed it from one serial context (the `AudioServer` queue). MP3 frames are
/// self-synchronising, so a listener that joins mid-stream still decodes from its first frame.
public final class MP3Encoder: @unchecked Sendable {
    /// MPEG-1 Layer III supports these input rates directly; anything else can't be encoded
    /// without resampling, so we fall back to the raw stream for those rooms.
    public static let supportedSampleRates: Set<Int> = [32_000, 44_100, 48_000]

    private let handle: shine_t
    private let channels: Int
    /// Samples per channel the encoder consumes per pass (1152 for MPEG-I).
    private let samplesPerPass: Int
    /// Leftover interleaved samples not yet forming a full pass.
    private var pending: [Int16] = []

    /// - Parameters:
    ///   - sampleRate: input sample rate; must be one of `supportedSampleRates`.
    ///   - channels: 1 (mono) or 2 (stereo).
    ///   - bitrate: output kbps (128 is a good default for Sonos radio).
    public init(sampleRate: Int, channels: Int, bitrate: Int = 128) throws {
        guard channels == 1 || channels == 2 else {
            throw SonosError.invalid("MP3 encoder supports mono or stereo only.")
        }
        guard shine_check_config(Int32(sampleRate), Int32(bitrate)) >= 0 else {
            throw SonosError.invalid("MP3 encoder does not support \(sampleRate) Hz at \(bitrate) kbps.")
        }
        var config = shine_config_t()
        shine_set_config_mpeg_defaults(&config.mpeg)
        config.wave.channels = channels == 1 ? PCM_MONO : PCM_STEREO
        config.wave.samplerate = Int32(sampleRate)
        config.mpeg.mode = channels == 1 ? MONO : JOINT_STEREO
        config.mpeg.bitr = Int32(bitrate)
        guard let handle = shine_initialise(&config) else {
            throw SonosError.invalid("Could not start the MP3 encoder.")
        }
        self.handle = handle
        self.channels = channels
        self.samplesPerPass = Int(shine_samples_per_pass(handle))
    }

    deinit { shine_close(handle) }

    /// Feeds more PCM and returns whatever complete MP3 frames are now ready (possibly empty).
    public func encode(_ pcm: Data) -> Data {
        guard !pcm.isEmpty else { return Data() }
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            pending.append(contentsOf: samples)
        }
        return drain()
    }

    /// Emits any buffered tail; call once when stopping.
    public func flush() -> Data {
        var out = drain()
        var written: Int32 = 0
        if let bytes = shine_flush(handle, &written), written > 0 {
            out.append(bytes, count: Int(written))
        }
        return out
    }

    /// Encodes as many full passes as `pending` holds.
    private func drain() -> Data {
        let frameSamples = samplesPerPass * channels
        guard pending.count >= frameSamples else { return Data() }
        var out = Data()
        var offset = 0
        while pending.count - offset >= frameSamples {
            var written: Int32 = 0
            pending.withUnsafeMutableBufferPointer { buf in
                let frame = buf.baseAddress! + offset
                if let bytes = shine_encode_buffer_interleaved(handle, frame, &written), written > 0 {
                    out.append(bytes, count: Int(written))
                }
            }
            offset += frameSamples
        }
        pending.removeFirst(offset)
        return out
    }
}
