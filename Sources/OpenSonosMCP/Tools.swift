import Foundation
import SonosKit

/// Live state behind the tools: the systems found on the network and the AirPlay hub.
actor Sonos {
    let client = SOAPClient()
    /// Volume ceiling for `set_volume` (OPENSONOS_MAX_VOLUME, default 30).
    let maxVolume: Int
    let backups: BackupStore
    private var systems: [Discovery.System] = []
    private var households: [String: Household] = [:]
    private var hub: AirPlayHub?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        maxVolume = environment["OPENSONOS_MAX_VOLUME"].flatMap(Int.init).map { max(0, min($0, 100)) } ?? 30
        backups = environment["OPENSONOS_BACKUPS"].map { BackupStore(directory: URL(filePath: $0, directoryHint: .isDirectory)) }
            ?? BackupStore()
    }

    // MARK: Topology

    func discover() async -> [String: Household] {
        let ips = await Discovery.discover(client: client)
        systems = await Discovery.systems(ips)
        for system in systems {
            if let hh = try? await client.loadHousehold(system.seed) { households[system.id] = hh }
        }
        return households
    }

    func loaded() async -> [String: Household] {
        households.isEmpty ? await discover() : households
    }

    /// A household reloaded from the network, so writes never build on stale topology.
    func fresh(_ id: String) async throws -> Household {
        guard let seed = systems.first(where: { $0.id == id })?.seed else { throw ToolError("Unknown system \(id)") }
        let hh = try await client.loadHousehold(seed)
        households[id] = hh
        return hh
    }

    /// The room for a name (case-insensitive) or any of its device uuids.
    func room(_ key: String) async throws -> (id: String, hh: Household, room: Room) {
        for (id, hh) in await loaded() {
            if let room = hh.rooms[key] ?? hh.rooms.values.first(where: { $0.devices.contains(key) })
                ?? hh.rooms.values.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                return (id, hh, room)
            }
        }
        throw ToolError("No room or device named \"\(key)\". Call list_systems to see the rooms.")
    }

    func coordinatorIP(_ key: String) async throws -> String {
        let r = try await room(key)
        guard let ip = r.hh.coordinator(of: r.room)?.ip, !ip.isEmpty else { throw ToolError("\(r.room.name) has no reachable coordinator") }
        return ip
    }

    /// The room's own primary player; its volume is the room's volume.
    func primaryIP(_ key: String) async throws -> String {
        let r = try await room(key)
        guard let ip = r.hh.devices[r.room.primary]?.ip, !ip.isEmpty else { throw ToolError("\(r.room.name) is not reachable") }
        return ip
    }

    // MARK: AirPlay

    func airplay() -> AirPlayHub {
        if let hub { return hub }
        let created = AirPlayHub(client: client)
        hub = created
        return created
    }

    func stopAirPlay() async {
        await hub?.stop()
        hub = nil
    }

    var airplayRunning: Bool { hub != nil }
}

// MARK: - Tool catalog

private func schema(_ properties: [String: JSON] = [:], required: [String] = []) -> JSON {
    ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
}

private let roomArg: JSON = ["type": "string", "description": "Room name (case-insensitive) or device uuid"]

private func arg(_ args: JSON, _ key: String) throws -> String {
    guard let value = args[key]?.string, !value.isEmpty else { throw ToolError("Missing argument \"\(key)\"") }
    return value
}

private func describe(_ hh: Household, id: String) -> JSON {
    .object([
        "household": .string(id),
        "rooms": .array(hh.sortedRooms.map { room in
            .object([
                "name": .string(room.name),
                "primary": .string(room.primary),
                "kind": .string(room.kind.rawValue),
                "coordinator": .string(hh.coordinator(of: room)?.room ?? ""),
                "devices": .array(hh.members(of: room).map { d in
                    .object([
                        "uuid": .string(d.uuid), "model": .string(d.displayModel), "ip": .string(d.ip),
                        "role": .string(d.role.rawValue), "channel": .string(d.channel),
                        "legacyStreamer": .bool(d.isLegacyStreamer),
                    ])
                }),
            ])
        }),
    ])
}

private func describe(_ steps: [Step], _ hh: Household) -> JSON {
    .array(steps.map { .string($0.describe(hh)) })
}

/// Resolves the bar and its satellite roles into Planner input.
private func satellitePlan(_ sonos: Sonos, _ args: JSON, fresh: Bool) async throws -> (String, Household, [Step]) {
    let bar = try await sonos.room(try arg(args, "bar"))
    let hh = fresh ? try await sonos.fresh(bar.id) : bar.hh
    guard let barDevice = hh.devices[bar.room.primary], barDevice.role == .soundbar || bar.room.kind == .homeTheater else {
        throw ToolError("\(bar.room.name) is not a soundbar room")
    }
    var assignments: [String: Role] = [:]
    for (key, value) in args["satellites"]?.object ?? [:] {
        let role = Role(rawValue: value.string ?? "")
        guard role.htToken != nil else {
            throw ToolError("\"\(value.string ?? "")\" is not a satellite role. Use sub, surround_left, surround_right, front_left or front_right.")
        }
        let uuid: String
        if hh.devices[key] != nil { uuid = key }
        else if let room = hh.rooms.values.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }), room.kind == .single {
            uuid = room.primary
        } else {
            throw ToolError("\"\(key)\" is not a single speaker in the same system as \(bar.room.name). Use its uuid from list_systems.")
        }
        assignments[uuid] = role
    }
    return (bar.id, hh, Planner.layout(hh, bar: barDevice.uuid, assignments: assignments))
}

func makeTools(_ sonos: Sonos) -> [Tool] {
    let satellites: JSON = [
        "type": "object",
        "description": """
        The bar's complete satellite layout: speaker (room name or uuid) -> role \
        (sub, surround_left, surround_right, front_left, front_right). Current satellites left out are unbonded.
        """,
        "additionalProperties": ["type": "string"],
    ]
    let confirm: JSON = ["type": "boolean", "description": "Must be true. Ask the user first."]

    return [
        Tool(name: "list_systems",
             description: "Finds every Sonos system (S1 and S2) on the network and lists rooms, devices, roles and channels.",
             schema: schema(["refresh": ["type": "boolean", "description": "Scan the network again"]])) { args in
            let all = args["refresh"]?.bool == true ? await sonos.discover() : await sonos.loaded()
            if all.isEmpty { throw ToolError("No Sonos devices found. Is this machine on the same network (and allowed Local Network access)?") }
            return .array(all.sorted { $0.key < $1.key }.map { describe($0.value, id: $0.key) })
        },

        Tool(name: "now_playing", description: "What a room's group is playing.",
             schema: schema(["room": roomArg], required: ["room"])) { args in
            let np = try await sonos.client.nowPlaying(try await sonos.coordinatorIP(try arg(args, "room")))
            return ["state": .string(np.state), "source": .string(String(describing: np.source)),
                    "title": .string(np.title), "artist": .string(np.artist), "album": .string(np.album)]
        },

        Tool(name: "get_volume", description: "A room's volume (0-100).",
             schema: schema(["room": roomArg], required: ["room"])) { args in
            .number(Double(try await sonos.client.volume(try await sonos.primaryIP(try arg(args, "room")))))
        },

        Tool(name: "set_volume",
             description: "Sets a room's volume. Refuses values above OPENSONOS_MAX_VOLUME (default 30).",
             schema: schema(["room": roomArg, "volume": ["type": "integer", "minimum": 0, "maximum": 100]],
                            required: ["room", "volume"]),
             writes: true) { args in
            guard let volume = args["volume"]?.int, volume >= 0 else { throw ToolError("Missing argument \"volume\"") }
            guard volume <= sonos.maxVolume else {
                throw ToolError("Refusing volume \(volume): the limit is \(sonos.maxVolume) (OPENSONOS_MAX_VOLUME).")
            }
            try await sonos.client.setVolume(try await sonos.primaryIP(try arg(args, "room")), volume)
            return .number(Double(volume))
        },

        Tool(name: "transport", description: "Play, pause, next or previous on a room's group.",
             schema: schema(["room": roomArg, "action": ["type": "string", "enum": ["play", "pause", "next", "previous"]]],
                            required: ["room", "action"]),
             writes: true) { args in
            let ip = try await sonos.coordinatorIP(try arg(args, "room"))
            switch try arg(args, "action") {
            case "play": try await sonos.client.play(ip)
            case "pause": try await sonos.client.pause(ip)
            case "next": try await sonos.client.next(ip)
            case "previous": try await sonos.client.previous(ip)
            case let other: throw ToolError("Unknown action \(other)")
            }
            return .string(try await sonos.client.transportState(ip))
        },

        Tool(name: "plan_satellites",
             description: """
             Plans how to give a soundbar a satellite layout (sub, rears, fronts — any Sonos speaker can be a front) \
             without changing anything. Returns the ordered bonding steps.
             """,
             schema: schema(["bar": roomArg, "satellites": satellites], required: ["bar", "satellites"])) { args in
            let (_, hh, steps) = try await satellitePlan(sonos, args, fresh: false)
            return ["steps": describe(steps, hh)]
        },

        Tool(name: "apply_satellites",
             description: """
             Bonds satellites to a soundbar (see plan_satellites). Saves a topology backup first, retries while a \
             speaker is not ready (UPnP 800) and restores the bar's surround settings afterwards. Speakers drop out \
             briefly while they rebond.
             """,
             schema: schema(["bar": roomArg, "satellites": satellites, "confirm": confirm],
                            required: ["bar", "satellites", "confirm"]),
             writes: true) { args in
            guard args["confirm"]?.bool == true else { throw ToolError("Not confirmed. Show the user plan_satellites and pass confirm=true.") }
            let (id, hh, steps) = try await satellitePlan(sonos, args, fresh: true)
            if steps.isEmpty { return ["steps": [], "note": "Already in that layout."] }
            let backup = try sonos.backups.save(hh, label: "before satellites")
            let log = Log()
            _ = try await Bonder(client: sonos.client).run(steps, on: hh) { await log.add($0) }
            _ = try? await sonos.fresh(id)
            return ["steps": describe(steps, hh), "backup": .string(backup.file), "log": .array(await log.lines)]
        },

        Tool(name: "list_backups", description: "Saved topology backups, newest first.", schema: schema()) { _ in
            .array(sonos.backups.list().map { ["file": .string($0.file), "label": .string($0.label), "created": .string($0.created)] })
        },

        Tool(name: "restore_backup",
             description: "Plans (confirm=false) or applies (confirm=true) the bonding steps that bring a system back to a backup.",
             schema: schema(["file": ["type": "string"], "confirm": confirm], required: ["file"]),
             writes: true) { args in
            let file = try arg(args, "file")
            let backup = try sonos.backups.load(sonos.backups.directory.appending(path: file))
            // The backup's system is the one that holds its devices.
            let anyDevice = backup.household.devices.keys.first ?? ""
            let id = try await sonos.room(anyDevice).id
            let hh = try await sonos.fresh(id)
            let steps = Planner.restore(hh, to: backup.household)
            guard args["confirm"]?.bool == true, !steps.isEmpty else { return ["steps": describe(steps, hh), "applied": false] }
            try sonos.backups.save(hh, label: "before restore")
            let log = Log()
            _ = try await Bonder(client: sonos.client).run(steps, on: hh) { await log.add($0) }
            return ["steps": describe(steps, hh), "applied": true, "log": .array(await log.lines)]
        },

        Tool(name: "airplay_start",
             description: """
             Advertises every Sonos room as its own AirPlay target from this machine (S1 rooms too). \
             Audio is re-streamed only while a sender has picked a room. Stays up while this server runs.
             """,
             schema: schema(), writes: true) { _ in
            let hub = await sonos.airplay()
            await hub.refresh()
            hub.keepFresh()
            return .array(hub.targets.map { .string("\($0.name): \($0.state)") })
        },

        Tool(name: "airplay_status", description: "AirPlay targets and which rooms are being fed by which sender.",
             schema: schema()) { _ in
            guard await sonos.airplayRunning else { return ["running": false] }
            let hub = await sonos.airplay()
            return [
                "running": true,
                "targets": .array(hub.targets.map { ["room": .string($0.name), "state": .string($0.state)] }),
                "links": .array(hub.bridge.links.map { link in
                    ["room": .string(hub.targets.first { $0.primary == link.room }?.name ?? link.room),
                     "source": .string(hub.targets.first { $0.primary == link.source }?.name ?? link.source),
                     "delayMs": .number(Double(link.delayMs))]
                }),
            ]
        },

        Tool(name: "airplay_link",
             description: "Also plays the AirPlay sender of room `source` in `room` (works across S1 and S2).",
             schema: schema(["room": roomArg, "source": roomArg], required: ["room", "source"]), writes: true) { args in
            guard await sonos.airplayRunning else { throw ToolError("Call airplay_start first.") }
            let hub = await sonos.airplay()
            guard let room = hub.room(try arg(args, "room")), let source = hub.room(try arg(args, "source")) else {
                throw ToolError("Unknown room")
            }
            try await hub.link(room.primary, to: source.primary)
            return .string("\(room.name) now plays \(source.name)'s AirPlay stream")
        },

        Tool(name: "airplay_unlink", description: "Stops a room started with airplay_link.",
             schema: schema(["room": roomArg], required: ["room"]), writes: true) { args in
            let hub = await sonos.airplay()
            guard let room = hub.room(try arg(args, "room")) else { throw ToolError("Unknown room") }
            await hub.unlink(room.primary)
            return .string("Stopped \(room.name)")
        },

        Tool(name: "airplay_set_delay", description: "Delays one bridged room's output (0-2000 ms) to line up rooms.",
             schema: schema(["room": roomArg, "ms": ["type": "integer", "minimum": 0, "maximum": 2000]], required: ["room", "ms"]),
             writes: true) { args in
            let hub = await sonos.airplay()
            guard let room = hub.room(try arg(args, "room")), let ms = args["ms"]?.int else { throw ToolError("Need room and ms") }
            hub.setDelay(room.primary, ms: ms)
            return .number(Double(ms))
        },

        Tool(name: "airplay_stop", description: "Stops advertising AirPlay targets and ends every bridged stream.",
             schema: schema(), writes: true) { _ in
            await sonos.stopAirPlay()
            return ["running": false]
        },
    ]
}

/// Collects Bonder progress for the tool result.
private actor Log {
    private(set) var lines: [JSON] = []
    func add(_ event: Bonder.Event) {
        switch event {
        case let .started(i, text): lines.append(.string("\(i + 1). \(text)"))
        case let .retrying(text): lines.append(.string("   \(text)"))
        case let .finished(i): lines.append(.string("   step \(i + 1) done"))
        case let .restoredEQ(ip): lines.append(.string("Restored surround settings on \(ip)"))
        }
    }
}
