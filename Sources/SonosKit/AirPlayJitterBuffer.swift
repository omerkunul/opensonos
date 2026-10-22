import Foundation

/// Reorders decoded AirPlay audio packets by RTP sequence number so Wi-Fi reordering, duplicates
/// and lost packets don't reach the speaker as clicks. Packets go in as they arrive; `pop` hands
/// them out strictly in sequence, substituting silence for a packet that never came. Not
/// thread-safe: the owning pipeline serializes access.
struct AirPlayJitterBuffer {
    /// PCM bytes in one packet (frames × channels × 2); the size of a silence substitute.
    let packetBytes: Int
    /// Packets to collect before playback (re)starts, absorbing arrival jitter.
    let prebuffer: Int
    /// Depth beyond which the oldest packets are skipped, bounding latency if the sender's
    /// clock runs faster than ours.
    let maxDepth: Int

    private var packets: [UInt16: Data] = [:]
    private var next: UInt16?
    private(set) var isPlaying = false
    /// True once a packet has been played since the last reset; earlier sequence numbers are late.
    private var hasPlayed = false
    private(set) var lost = 0
    private(set) var late = 0

    init(packetBytes: Int, prebuffer: Int, maxDepth: Int) {
        self.packetBytes = packetBytes
        self.prebuffer = prebuffer
        self.maxDepth = maxDepth
    }

    /// Packets held at or after the next one to play.
    var depth: Int { packets.count }

    mutating func insert(seq: UInt16, pcm: Data) {
        if let n = next, Int16(bitPattern: seq &- n) < 0 {
            guard !hasPlayed else { late += 1; return }          // already played past it
            next = seq                                            // earlier packet while buffering
        }
        packets[seq] = pcm
        if next == nil { next = seq }
        if !isPlaying, packets.count >= prebuffer { isPlaying = true }
        while packets.count > maxDepth, let n = next {            // sender clock ahead: catch up
            packets[n] = nil
            next = n &+ 1
        }
    }

    /// The next packet in sequence, silence if it is missing, or nil while (re)buffering.
    mutating func pop() -> Data? {
        guard isPlaying, let n = next else { return nil }
        if packets.isEmpty {                     // ran dry: stop and refill before resuming
            isPlaying = false
            return nil
        }
        next = n &+ 1
        hasPlayed = true
        if let pcm = packets.removeValue(forKey: n) { return pcm }
        lost += 1
        return Data(count: packetBytes)
    }

    /// Drops everything (a sender FLUSH or seek); playback restarts after a fresh prebuffer.
    mutating func reset() {
        packets = [:]
        next = nil
        isPlaying = false
        hasPlayed = false
    }
}
