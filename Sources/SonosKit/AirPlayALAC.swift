#if canImport(AudioToolbox)
import AudioToolbox
import Foundation

/// Decodes AirPlay's ALAC (Apple Lossless) frames to 16-bit little-endian interleaved PCM
/// with CoreAudio's AudioConverter, configured from the ALAC magic cookie the SDP describes.
final class ALACDecoder {
    private let converter: AudioConverterRef
    let frameLength: UInt32
    let channels: UInt32

    /// Carries one ALAC packet into the converter's C input callback. The input bytes and the
    /// packet description live in stable allocations for the span of one decode, never in an
    /// escaping `withUnsafeBytes` pointer.
    private final class Feed {
        var input: UnsafeMutableRawPointer?
        var count = 0
        var desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var consumed = false
        deinit { desc.deallocate() }
    }
    private let feed = Feed()

    /// Builds a decoder from the SDP `fmtp` fields (payload type first, as `SDP` collects them).
    convenience init?(fmtp f: [Int], sampleRate: Int) {
        guard f.count >= 12 else { return nil }
        let cookie = ALACDecoder.cookie(fmtp: f)
        self.init(magicCookie: cookie, sampleRate: f.last ?? sampleRate,
                  channels: f[7], frameLength: f[1])
    }

    init?(magicCookie: Data, sampleRate: Int, channels channelCount: Int, frameLength frames: Int) {
        frameLength = UInt32(frames)
        channels = UInt32(max(1, channelCount))
        let rate = Double(sampleRate)

        var input = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: UInt32(kAppleLosslessFormatFlag_16BitSourceData),
            mBytesPerPacket: 0, mFramesPerPacket: frameLength, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)

        var conv: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &conv) == noErr, let conv else { return nil }
        converter = conv
        let set = magicCookie.withUnsafeBytes { ptr in
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                      UInt32(magicCookie.count), ptr.baseAddress!)
        }
        guard set == noErr else { AudioConverterDispose(conv); return nil }
    }

    deinit { AudioConverterDispose(converter) }

    /// Decodes one ALAC packet to interleaved 16-bit PCM, or nil on failure.
    func decode(_ alac: Data) -> Data? {
        guard !alac.isEmpty else { return nil }
        let bytes = [UInt8](alac)
        let input = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        input.copyMemory(from: bytes, byteCount: bytes.count)
        feed.input = input
        feed.count = bytes.count
        feed.consumed = false
        defer { input.deallocate(); feed.input = nil }

        let capacity = Int(frameLength) * Int(channels) * 2
        var pcm = Data(count: capacity)
        var ioFrames = frameLength
        let status = pcm.withUnsafeMutableBytes { outPtr -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels,
                                      mDataByteSize: UInt32(capacity),
                                      mData: outPtr.baseAddress))
            let ctx = Unmanaged.passUnretained(feed).toOpaque()
            return AudioConverterFillComplexBuffer(converter, Self.inputProc, ctx, &ioFrames, &list, nil)
        }
        guard status == noErr, ioFrames > 0 else { return nil }
        let produced = Int(ioFrames) * Int(channels) * 2
        if produced < pcm.count { pcm.removeSubrange(produced..<pcm.count) }
        return pcm
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberPackets, ioData, outPacketDesc, inUserData in
        let feed = Unmanaged<ALACDecoder.Feed>.fromOpaque(inUserData!).takeUnretainedValue()
        if feed.consumed || feed.input == nil {
            ioNumberPackets.pointee = 0
            return noErr
        }
        feed.consumed = true
        ioNumberPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 0
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.count)
        ioData.pointee.mBuffers.mData = feed.input
        if let outPacketDesc {
            feed.desc.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(feed.count))
            outPacketDesc.pointee = feed.desc
        }
        return noErr
    }

    /// The 24-byte ALACSpecificConfig (big-endian) CoreAudio wants as the decode magic cookie,
    /// built from the SDP `fmtp` fields: [payloadType, frameLength, version, bitDepth, pb, mb,
    /// kb, channels, maxRun, maxFrameBytes, avgBitRate, sampleRate].
    static func cookie(fmtp f: [Int]) -> Data {
        var c = Data()
        func be32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { c.append(contentsOf: $0) } }
        func be16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { c.append(contentsOf: $0) } }
        be32(UInt32(f[1]))            // frameLength
        c.append(UInt8(f[2] & 0xff))  // compatibleVersion
        c.append(UInt8(f[3] & 0xff))  // bitDepth
        c.append(UInt8(f[4] & 0xff))  // pb
        c.append(UInt8(f[5] & 0xff))  // mb
        c.append(UInt8(f[6] & 0xff))  // kb
        c.append(UInt8(f[7] & 0xff))  // numChannels
        be16(UInt16(f[8]))            // maxRun
        be32(UInt32(f[9]))            // maxFrameBytes
        be32(UInt32(f[10]))           // avgBitRate
        be32(UInt32(f.last ?? 44_100))// sampleRate
        return c
    }
}
#endif
