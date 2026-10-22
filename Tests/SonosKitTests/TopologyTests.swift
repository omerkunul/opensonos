import Foundation
import Testing
@testable import SonosKit

let BAR = "RINCON_0000AA00000101400"
let SUB = "RINCON_0000AA00000401400"
let P3_L = "RINCON_0000AA00000501400"
let P3_R = "RINCON_0000AA00000601400"
let P1_L = "RINCON_0000AA00000201400"
let P1_R = "RINCON_0000AA00000301400"

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

func baseline() throws -> Household { try parseZoneGroupState(fixture("zone_group_state.xml")) }

@Test func channelMapRoundtrip() {
    let m = ChannelMap.parse("\(BAR):LF,RF;\(SUB):SW")
    #expect(m.map(\.0) == [BAR, SUB] && m.map(\.1) == ["LF,RF", "SW"])
    #expect(ChannelMap.format(m) == "\(BAR):LF,RF;\(SUB):SW")
}

@Test func homeTheaterRoles() throws {
    let h = try baseline()
    #expect(Set(h.rooms.keys) == [BAR, P1_L])
    let room = try #require(h.rooms[BAR])
    #expect(room.kind == .homeTheater)
    #expect(Set(room.devices) == [BAR, SUB, P3_L, P3_R])
    #expect(h.devices[SUB]?.role == .sub && h.devices[SUB]?.bondedTo == BAR)
    #expect(h.devices[P3_L]?.role == .surroundLeft)
    #expect(h.devices[P3_R]?.role == .surroundRight)
    #expect(h.devices[BAR]?.role == .soundbar)
}

@Test func stereoPair() throws {
    let h = try baseline()
    #expect(h.rooms[P1_L]?.kind == .stereoPair)
    #expect(h.devices[P1_R]?.bondedTo == P1_L)
    #expect(h.devices[P1_L]?.role == .pairLeft)
    #expect(h.rooms[P1_L]?.pairMapString == "\(P1_L):LF,LF;\(P1_R):RF,RF")
}

@Test func lookupByRoomAndIP() throws {
    let h = try baseline()
    #expect(try h.device("living room").uuid == BAR)
    #expect(try h.device("10.0.0.18").uuid == P1_R)
}

@Test func frontsWithHeightSuffix() throws {
    var xml = try fixture("zone_group_state.xml")
    xml = xml.replacingOccurrences(of: "ChannelMapSet=\"\(P1_L):LF,LF;\(P1_R):RF,RF\"", with: "")
    xml = xml.replacingOccurrences(of: "\(BAR):LF,RF;", with: "\(BAR):CC;\(P1_L):LF,LTF;\(P1_R):RF,RTF;")
    let h = try parseZoneGroupState(xml)
    #expect(h.devices[BAR]?.role == .soundbar)
    #expect(h.devices[P1_L]?.role == .frontLeft && h.devices[P1_L]?.bondedTo == BAR)
    #expect(h.devices[P1_R]?.role == .frontRight)
    #expect(h.devices[SUB]?.role == .sub)
}

@Test func liveFrontsFixtureTolerated() throws {
    // A device in a map but missing from the member list mid-bonding.
    let h = try parseZoneGroupState(fixture("zgs_fronts_live.xml"))
    let room = try #require(h.rooms[BAR])
    #expect(room.devices.allSatisfy { h.devices[$0] != nil })
}

@Test func soapResponseUnescapesZGS() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "zgs_response.xml", withExtension: nil, subdirectory: "Fixtures")))
    let resp = try SOAPClient.parseResponse("GetZoneGroupState", data)
    let zgs = try #require(resp["ZoneGroupState"])
    #expect(try parseZoneGroupState(zgs).devices.count > 0)
}

@Test func soapFault() {
    let body = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail>\
    <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>800</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """
    #expect(SOAPClient.fault("AddHTSatellite", Data(body.utf8)).code == 800)
}

@Test func roleCodable() throws {
    let data = try JSONEncoder().encode([Role.frontLeft, .unknown("XX")])
    #expect(String(decoding: data, as: UTF8.self) == #"["front_left","unknown:XX"]"#)
    #expect(try JSONDecoder().decode([Role].self, from: data) == [.frontLeft, .unknown("XX")])
}

// MARK: - Planlama

@Test func restoreNoopWhenUnchanged() throws {
    let h = try baseline()
    #expect(Planner.restore(h, to: h).isEmpty)
}

@Test func restoreAfterFrontExperiment() throws {
    let before = try baseline()
    var xml = try fixture("zone_group_state.xml")
    xml = xml.replacingOccurrences(of: "ChannelMapSet=\"\(P1_L):LF,LF;\(P1_R):RF,RF\"", with: "")
    xml = xml.replacingOccurrences(of: "\(BAR):LF,RF;\(SUB):SW;", with: "\(BAR):LF,RF;\(SUB):SW;\(P1_L):LF;\(P1_R):RF;")
    let after = try parseZoneGroupState(xml)
    #expect(after.devices[P1_L]?.role == .frontLeft)
    let steps = Planner.restore(after, to: before)
    #expect(steps.count == 3)
    #expect(steps.last == .createPair(left: P1_L, right: P1_R))
}

@Test func layoutPlayOnesAsFronts() throws {
    let h = try baseline()
    let steps = Planner.layout(h, bar: BAR, assignments: [
        SUB: .sub, P3_L: .surroundLeft, P3_R: .surroundRight, P1_L: .frontLeft, P1_R: .frontRight,
    ])
    #expect(steps == [
        .separatePair(primary: P1_L),
        .addSatellite(bar: BAR, device: P1_L, token: "LF"),
        .addSatellite(bar: BAR, device: P1_R, token: "RF"),
    ])
}

@Test func layoutSwapRoles() throws {
    // Current live layout: Play:3 front, Play:1 rear. Swapping = 4 unbonds + 4 adds.
    let h = try parseZoneGroupState(fixture("zgs_fronts_live.xml"))
    let steps = Planner.layout(h, bar: BAR, assignments: [
        SUB: .sub, P1_L: .frontLeft, P1_R: .frontRight, P3_L: .surroundLeft, P3_R: .surroundRight,
    ])
    let adds = steps.filter { if case .addSatellite = $0 { true } else { false } }
    #expect(adds.count <= 4)
    #expect(steps.firstIndex { if case .addSatellite = $0 { true } else { false } }
            ?? 0 > steps.lastIndex { if case .removeSatellite = $0 { true } else { false } } ?? -1)
}

@Test func pythonBackupLoads() throws {
    let url = try #require(Bundle.module.url(forResource: "python_backup.json", withExtension: nil, subdirectory: "Fixtures"))
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: url, to: dir.appending(path: "20261019-210219-baslangic.json"))
    let store = BackupStore(directory: dir)
    let b = try #require(store.list().first)
    #expect(b.household.devices.count >= 6)
    #expect(b.createdDate != nil)
    // A backup is consistent with its own ZGS: the restore plan is empty.
    #expect(Planner.restore(try parseZoneGroupState(b.zoneGroupState), to: b.household).isEmpty)

    let saved = try store.save(b.household, label: "Test backup")
    #expect(saved.file.hasSuffix("-test-backup.json"))
    #expect(try store.load(dir.appending(path: saved.file)).household.rooms.count == b.household.rooms.count)
}
