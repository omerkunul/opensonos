import Testing
@testable import SonosKit

@Test func airPlayVolumeParsesParameterBody() {
    #expect(AirPlayVolume.parse("volume: -11.250000\r\n") == -11.25)
    #expect(AirPlayVolume.parse("progress: 1/2/3\r\n") == nil)
}

@Test func airPlayVolumeIsRelativeToConnectLevel() {
    let v = AirPlayVolume(senderDB: -15, roomVolume: 7)          // phone at half, room at 7
    #expect(v.roomVolume(forSenderDB: -15) == 7)                 // connecting changes nothing
    #expect(v.roomVolume(forSenderDB: 0) == 100)                 // phone max → room max
    #expect(v.roomVolume(forSenderDB: -144) == 0)                // mute → 0
    #expect(v.roomVolume(forSenderDB: -7.5) == 54)               // halfway up the remaining range
    #expect(v.roomVolume(forSenderDB: -22.5) == 4)               // halfway down
    #expect(AirPlayVolume(senderDB: 0, roomVolume: 30).roomVolume(forSenderDB: 0) == 30)
}
