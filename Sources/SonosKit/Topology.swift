import Foundation

/// Channel map formats:
///   Stereo pair (ChannelMapSet):    RINCON_A:LF,LF;RINCON_B:RF,RF
///   Home theater (HTSatChanMapSet): RINCON_BAR:LF,RF;RINCON_SUB:SW;RINCON_L:LR;RINCON_R:RR
/// Each satellite only sees the bar and itself in its map; the full layout
/// is the union of all members' maps.
public enum ChannelMap {
    /// Bar tokens. The Playbar accepts "CC" but reverts it after ~1 min; "LF,RF" sticks.
    public static let barTokens: Set<String> = ["LF,RF", "CC"]

    /// "UUID:TOKEN;UUID:TOKEN" -> ordered [(UUID, TOKEN)]
    public static func parse(_ value: String?) -> [(String, String)] {
        (value ?? "").split(separator: ";").compactMap { part in
            guard let i = part.firstIndex(of: ":") else { return nil }
            return (part[..<i].trimmingCharacters(in: .whitespaces),
                    part[part.index(after: i)...].trimmingCharacters(in: .whitespaces))
        }
    }

    public static func format(_ entries: [(String, String)]) -> String {
        entries.map { "\($0.0):\($0.1)" }.joined(separator: ";")
    }

    /// "LF" and "LF,LTF" are the same channel (firmware may add a height channel);
    /// pair tokens ("LF,LF") are compared exactly.
    public static func sameChannel(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let pairCodes: Set<String> = ["LF,LF", "RF,RF"]
        return firstToken(a) == firstToken(b) && !pairCodes.contains(a) && !pairCodes.contains(b)
    }

    public static func firstToken(_ s: String) -> String {
        s.split(separator: ",").first.map(String.init) ?? s
    }
}

public enum Role: Hashable, Sendable, Codable {
    case soundbar, sub, surroundLeft, surroundRight, frontLeft, frontRight
    case pairLeft, pairRight, standalone
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "soundbar": self = .soundbar
        case "sub": self = .sub
        case "surround_left": self = .surroundLeft
        case "surround_right": self = .surroundRight
        case "front_left": self = .frontLeft
        case "front_right": self = .frontRight
        case "pair_left": self = .pairLeft
        case "pair_right": self = .pairRight
        case "standalone": self = .standalone
        default: self = .unknown(rawValue.hasPrefix("unknown:") ? String(rawValue.dropFirst(8)) : rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .soundbar: "soundbar"
        case .sub: "sub"
        case .surroundLeft: "surround_left"
        case .surroundRight: "surround_right"
        case .frontLeft: "front_left"
        case .frontRight: "front_right"
        case .pairLeft: "pair_left"
        case .pairRight: "pair_right"
        case .standalone: "standalone"
        case let .unknown(token): "unknown:\(token)"
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var label: String {
        switch self {
        case .soundbar: "Soundbar"
        case .sub: "Sub"
        case .surroundLeft: "Rear left"
        case .surroundRight: "Rear right"
        case .frontLeft: "Front left"
        case .frontRight: "Front right"
        case .pairLeft: "Pair left"
        case .pairRight: "Pair right"
        case .standalone: "Single"
        case let .unknown(token): "Unknown (\(token))"
        }
    }

    /// Channel token sent when adding as a home theater satellite.
    public var htToken: String? {
        switch self {
        case .sub: "SW"
        case .surroundLeft: "LR"
        case .surroundRight: "RR"
        case .frontLeft: "LF"
        case .frontRight: "RF"
        default: nil
        }
    }

    /// Satellite assignment order: Sub, rears, fronts.
    public static let satelliteRoles: [Role] = [.sub, .surroundLeft, .surroundRight, .frontLeft, .frontRight]

    static func homeTheater(_ token: String) -> Role {
        let table: [String: Role] = ["LF,RF": .soundbar, "CC": .soundbar, "SW": .sub, "LR": .surroundLeft,
                                     "RR": .surroundRight, "LF": .frontLeft, "RF": .frontRight]
        return table[token] ?? table[ChannelMap.firstToken(token)] ?? .unknown(token)
    }

    static func pair(_ token: String) -> Role {
        let table: [String: Role] = ["LF": .pairLeft, "RF": .pairRight, "SW": .sub]
        return table[token] ?? table[ChannelMap.firstToken(token)] ?? .unknown(token)
    }
}

public struct Device: Codable, Sendable, Identifiable, Hashable {
    public var uuid: String
    public var room: String
    public var ip: String
    public var model: String = ""
    public var modelNumber: String = ""
    public var software: String = ""
    /// Sonos software generation ("1" = S1-only gen-1 hardware, "2" = current); empty if unknown.
    public var swGen: String = ""
    /// Housing colour reported by the speaker ("Black", "White"); empty on older hardware.
    public var color: String = ""
    public var invisible = false
    public var isSatellite = false
    public var role: Role = .standalone
    public var channel: String = ""
    /// UUID of the bar or pair primary; empty when not bonded.
    public var bondedTo: String = ""

    public var id: String { uuid }
    public var displayModel: String { model.isEmpty ? uuid : model }

    /// Gen-1 S1-platform players reject an endless PCM/WAV stream and must be fed MP3 over
    /// `x-rincon-mp3radio://`. Primary signal is the reported software generation; the known
    /// problem model (PLAY:5 gen 1, "S5") is also matched in case `swGen` wasn't read.
    public var isLegacyStreamer: Bool { swGen == "1" || Device.legacyStreamModels.contains(modelNumber.uppercased()) }
    static let legacyStreamModels: Set<String> = ["S5"]

    enum CodingKeys: String, CodingKey {
        case uuid, room, ip, model, software, swGen, color, invisible, role, channel
        case modelNumber = "model_number", isSatellite = "is_satellite", bondedTo = "bonded_to"
    }

    public init(uuid: String, room: String, ip: String) {
        self.uuid = uuid; self.room = room; self.ip = ip
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        room = try c.decodeIfPresent(String.self, forKey: .room) ?? ""
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        modelNumber = try c.decodeIfPresent(String.self, forKey: .modelNumber) ?? ""
        software = try c.decodeIfPresent(String.self, forKey: .software) ?? ""
        swGen = try c.decodeIfPresent(String.self, forKey: .swGen) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        invisible = try c.decodeIfPresent(Bool.self, forKey: .invisible) ?? false
        isSatellite = try c.decodeIfPresent(Bool.self, forKey: .isSatellite) ?? false
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .standalone
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        bondedTo = try c.decodeIfPresent(String.self, forKey: .bondedTo) ?? ""
    }
}

public enum RoomKind: String, Codable, Sendable {
    case single, stereoPair = "stereo_pair", homeTheater = "home_theater"
}

public struct Room: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var primary: String
    public var devices: [String]
    public var kind: RoomKind = .single
    public var htMap: [String: String] = [:]
    public var pairMap: [String: String] = [:]

    public var id: String { primary }

    enum CodingKeys: String, CodingKey {
        case name, primary, devices, kind, htMap = "ht_map", pairMap = "pair_map"
    }

    public init(name: String, primary: String) {
        self.name = name; self.primary = primary; devices = [primary]
    }

    /// ChannelMapSet with the left device first.
    public var pairMapString: String {
        ChannelMap.format(pairMap.sorted { ($0.value.hasPrefix("LF") ? 0 : 1, $0.key) < ($1.value.hasPrefix("LF") ? 0 : 1, $1.key) }
            .map { ($0.key, $0.value) })
    }
}

public struct Group: Codable, Sendable, Hashable {
    public var id: String
    public var coordinator: String
    public var rooms: [String] = []
}

public struct Household: Codable, Sendable {
    public var devices: [String: Device] = [:]
    public var rooms: [String: Room] = [:]
    public var groups: [Group] = []
    /// Raw ZoneGroupState; stored as a separate field in backups.
    public var raw = ""

    enum CodingKeys: String, CodingKey { case devices, rooms, groups }

    public init() {}

    public var sortedRooms: [Room] {
        rooms.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Device by UUID, IP or room name (room name -> primary).
    public func device(_ key: String) throws -> Device {
        if let d = devices[key] { return d }
        if let d = devices.values.first(where: { $0.ip == key }) { return d }
        if let r = rooms.values.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }),
           let d = devices[r.primary] { return d }
        throw SonosError.notFound(key)
    }

    public func room(of uuid: String) throws -> Room {
        guard let r = rooms.values.first(where: { $0.devices.contains(uuid) }) else { throw SonosError.notFound(uuid) }
        return r
    }

    public func members(of room: Room) -> [Device] { room.devices.compactMap { devices[$0] } }
}

// MARK: - Parsing

public func parseZoneGroupState(_ xml: String) throws -> Household {
    let root = try XNode.parse(xml)
    var hh = Household()
    hh.raw = xml

    struct Member { let group: String; let node: XNode; let isSatellite: Bool }
    var members: [Member] = []
    for zg in root.descendants("ZoneGroup") {
        hh.groups.append(Group(id: zg["ID"] ?? "", coordinator: zg["Coordinator"] ?? ""))
        for m in zg.children where m.name == "ZoneGroupMember" {
            members.append(Member(group: zg["ID"] ?? "", node: m, isSatellite: false))
            for s in m.children where s.name == "Satellite" {
                members.append(Member(group: zg["ID"] ?? "", node: s, isSatellite: true))
            }
        }
    }

    // 1) devices
    for m in members {
        let uuid = m.node["UUID"] ?? ""
        var d = Device(uuid: uuid, room: m.node["ZoneName"] ?? "", ip: ipFromLocation(m.node["Location"]))
        d.software = m.node["SoftwareVersion"] ?? ""
        d.invisible = m.node["Invisible"] == "1"
        d.isSatellite = m.isSatellite
        hh.devices[uuid] = d
    }

    // 2) home theater maps (union of every member's view)
    var htByBar: [String: [String: String]] = [:]
    var htOrder: [String] = []
    for m in members {
        let cmap = ChannelMap.parse(m.node["HTSatChanMapSet"])
        guard !cmap.isEmpty else { continue }
        let bar = cmap.first { ChannelMap.barTokens.contains($0.1) }?.0
            ?? cmap.first { hh.devices[$0.0].map { !$0.isSatellite } ?? false }?.0
            ?? cmap[0].0
        if htByBar[bar] == nil { htOrder.append(bar) }
        for (u, t) in cmap { htByBar[bar, default: [:]][u] = t }
    }

    // 3) stereo pair maps
    var pairByPrimary: [String: [String: String]] = [:]
    for m in members {
        let cmap = ChannelMap.parse(m.node["ChannelMapSet"])
        guard !cmap.isEmpty else { continue }
        let left = cmap.first { $0.1.hasPrefix("LF") }?.0 ?? cmap[0].0
        for (u, t) in cmap { pairByPrimary[left, default: [:]][u] = t }
    }

    for bar in htOrder {
        for (uuid, token) in htByBar[bar]! where hh.devices[uuid] != nil {
            hh.devices[uuid]!.channel = token
            hh.devices[uuid]!.role = uuid == bar ? .soundbar : Role.homeTheater(token)
            hh.devices[uuid]!.bondedTo = uuid == bar ? "" : bar
        }
    }
    for (primary, cmap) in pairByPrimary {
        for (uuid, token) in cmap where hh.devices[uuid]?.role == .standalone {
            hh.devices[uuid]!.channel = token
            hh.devices[uuid]!.role = Role.pair(token)
            hh.devices[uuid]!.bondedTo = uuid == primary ? "" : primary
        }
    }

    // 4) rooms
    for m in members where !m.isSatellite {
        let uuid = m.node["UUID"] ?? ""
        guard let d = hh.devices[uuid], d.bondedTo.isEmpty else { continue }  // invisible right side of a pair
        var room = Room(name: d.room, primary: uuid)
        // Mid-transition a device can be in a map but not yet in the member list.
        func others(_ map: [String: String]) -> [String] {
            map.keys.filter { $0 != uuid && hh.devices[$0] != nil }.sorted { roleOrder(hh.devices[$0]!.role) < roleOrder(hh.devices[$1]!.role) }
        }
        if let map = htByBar[uuid] {
            room.kind = .homeTheater
            room.htMap = map
            room.devices += others(map)
        } else if let map = pairByPrimary[uuid] {
            room.kind = .stereoPair
            room.pairMap = map
            room.devices += others(map)
        }
        hh.rooms[uuid] = room
        if let gi = hh.groups.firstIndex(where: { $0.id == m.group }) { hh.groups[gi].rooms.append(uuid) }
    }
    return hh
}

private func roleOrder(_ r: Role) -> Int {
    [Role.soundbar, .pairLeft, .pairRight, .frontLeft, .frontRight, .sub, .surroundLeft, .surroundRight]
        .firstIndex(of: r) ?? 99
}

private func ipFromLocation(_ loc: String?) -> String {
    guard let loc, let url = URL(string: loc) else { return "" }
    return url.host ?? ""
}

// MARK: - Live reads

public struct DeviceInfo: Sendable {
    public var modelName = "", modelNumber = "", displayVersion = "", swGen = "", color = ""
}

public extension SOAPClient {
    func zoneGroupState(_ ip: String) async throws -> String {
        guard let s = try await call(ip, .zoneGroupTopology, "GetZoneGroupState")["ZoneGroupState"] else {
            throw SonosError.badResponse("Missing ZoneGroupState")
        }
        return s
    }

    func deviceInfo(_ ip: String) async throws -> DeviceInfo {
        let root = try XNode.parse(try await get(ip, path: "/xml/device_description.xml"))
        func v(_ tag: String) -> String { root.descendants(tag).first?.text ?? "" }
        var name = v("modelName")
        if name.hasPrefix("Sonos ") { name.removeFirst(6) }
        return DeviceInfo(modelName: name, modelNumber: v("modelNumber"), displayVersion: v("displayVersion"), swGen: v("swGen"),
                          color: (try? await color(ip)) ?? "")
    }

    /// The housing colour from the speaker's discovery info; older hardware leaves it out.
    func color(_ ip: String) async throws -> String {
        struct Info: Decodable { struct Device: Decodable { var color: String? }; var device: Device }
        return try JSONDecoder().decode(Info.self, from: try await get(ip, path: "/info")).device.color ?? ""
    }

    func loadHousehold(_ ip: String, withModels: Bool = true) async throws -> Household {
        var hh = try parseZoneGroupState(try await zoneGroupState(ip))
        guard withModels else { return hh }
        let targets = hh.devices.values.filter { !$0.ip.isEmpty }.map { ($0.uuid, $0.ip) }
        let infos = await withTaskGroup(of: (String, DeviceInfo?).self) { group in
            for (uuid, ip) in targets { group.addTask { (uuid, try? await self.deviceInfo(ip)) } }
            return await group.reduce(into: [String: DeviceInfo]()) { if let i = $1.1 { $0[$1.0] = i } }
        }
        for (uuid, info) in infos {
            hh.devices[uuid]?.model = info.modelName
            hh.devices[uuid]?.modelNumber = info.modelNumber
            hh.devices[uuid]?.color = info.color
            hh.devices[uuid]?.swGen = info.swGen
            if !info.displayVersion.isEmpty { hh.devices[uuid]?.software = info.displayVersion }
        }
        return hh
    }

    /// Refreshes only the topology on top of a household whose models are already
    /// known (fast path while waiting during bonding).
    func refresh(_ ip: String, keeping old: Household) async throws -> Household {
        var hh = try parseZoneGroupState(try await zoneGroupState(ip))
        for (uuid, d) in old.devices where hh.devices[uuid] != nil {
            hh.devices[uuid]!.model = d.model
            hh.devices[uuid]!.modelNumber = d.modelNumber
            hh.devices[uuid]!.color = d.color
            hh.devices[uuid]!.swGen = d.swGen
            if !d.software.isEmpty { hh.devices[uuid]!.software = d.software }
        }
        return hh
    }
}
