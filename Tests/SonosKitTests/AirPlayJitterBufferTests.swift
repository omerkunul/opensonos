import Foundation
import Testing
@testable import SonosKit

private func pcm(_ v: UInt8) -> Data { Data(repeating: v, count: 4) }

@Test func jitterBufferReordersAndWaitsForPrebuffer() {
    var buffer = AirPlayJitterBuffer(packetBytes: 4, prebuffer: 3, maxDepth: 100)
    buffer.insert(seq: 11, pcm: pcm(11))
    buffer.insert(seq: 10, pcm: pcm(10))
    #expect(buffer.pop() == nil)                 // still prebuffering
    buffer.insert(seq: 12, pcm: pcm(12))
    #expect(buffer.pop() == pcm(10))
    #expect(buffer.pop() == pcm(11))
    #expect(buffer.pop() == pcm(12))
}

@Test func jitterBufferFillsLostPacketsWithSilenceAndDropsLateOnes() {
    var buffer = AirPlayJitterBuffer(packetBytes: 4, prebuffer: 2, maxDepth: 100)
    buffer.insert(seq: 65_535, pcm: pcm(1))
    buffer.insert(seq: 1, pcm: pcm(3))           // seq 0 lost, across the 16-bit wrap
    #expect(buffer.pop() == pcm(1))
    #expect(buffer.pop() == Data(count: 4))
    #expect(buffer.pop() == pcm(3))
    #expect(buffer.lost == 1)
    buffer.insert(seq: 0, pcm: pcm(2))           // arrived too late: ignored
    #expect(buffer.late == 1)
    #expect(buffer.pop() == nil)                 // ran dry → rebuffer
    #expect(!buffer.isPlaying)
}

@Test func jitterBufferBoundsDepth() {
    var buffer = AirPlayJitterBuffer(packetBytes: 4, prebuffer: 1, maxDepth: 3)
    for seq in UInt16(0)..<6 { buffer.insert(seq: seq, pcm: pcm(UInt8(seq))) }
    #expect(buffer.depth == 3)
    #expect(buffer.pop() == pcm(3))              // oldest skipped
}
