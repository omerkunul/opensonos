import Foundation
import OSLog

private let log = Logger(subsystem: "opensonos", category: "airplay-hub")

/// Turns every Sonos room on the network into its own AirPlay target, in one object.
///
/// It finds every Sonos system (S1 and S2 alike), advertises one `_raop._tcp` target per
/// room, and when a sender connects it points that room's group coordinator at an
/// `AirPlayBridge` stream. The sender's volume buttons move the room's volume relative to
/// where it is. Rooms in different systems can share one sender with `link`.
///
/// Nothing plays until a real AirPlay sender picks a room: the hub never starts playback
/// by itself.
///
/// ```swift
/// let hub = AirPlayHub()
/// await hub.refresh()          // discover, advertise
/// hub.keepFresh()              // re-scan every minute
/// ```
public final class AirPlayHub: @unchecked Sendable {
    /// A room the hub advertises.
    public struct Target: Sendable, Equatable {
        public let primary: String
        public let name: String
        public let household: String
        public let coordinatorIP: String
        public let state: String
    }

    public let receiver = AirPlayReceiver()
    public let bridge = AirPlayBridge()
    private let client: SOAPClient
    private let lock = NSLock()
    /// Topology per household id, refreshed by `refresh()`.
    private var households: [String: Household] = [:]
    private var states: [String: AirPlayStationState] = [:]
    private var rescan: Task<Void, Never>?
    /// Title shown in the Sonos app for a bridged room.
    public var title: @Sendable (_ roomName: String) -> String = { "AirPlay · \($0)" }

    public init(client: SOAPClient = SOAPClient()) {
        self.client = client
        wire()
    }

    deinit { rescan?.cancel() }

    // MARK: - Topology

    /// Discovers every Sonos system, reloads its rooms and syncs the advertised targets.
    /// Systems that do not answer keep their last known rooms.
    public func refresh() async {
        let ips = await Discovery.discover(client: client)
        let systems = await Discovery.systems(ips)
        for system in systems {
            guard let hh = try? await client.loadHousehold(system.seed, withModels: true) else { continue }
            lock.withLock { households[system.id] = hh }
        }
        let rooms = lock.withLock { () -> [String: String] in
            var rooms: [String: String] = [:]
            for hh in households.values { for room in hh.sortedRooms { rooms[room.primary] = room.name } }
            return rooms
        }
        receiver.sync(rooms: rooms)
        log.info("AirPlay hub: \(rooms.count) room(s) in \(systems.count) system(s)")
    }

    /// Calls `refresh()` every `interval` until `stop()`, so rooms added or regrouped show up.
    public func keepFresh(every interval: Duration = .seconds(60)) {
        rescan?.cancel()
        rescan = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.refresh()
            }
        }
    }

    /// Stops advertising and ends every bridged room.
    public func stop() async {
        rescan?.cancel(); rescan = nil
        receiver.stopAll()
        for source in bridge.sources { await bridge.end(source) }
    }

    /// Every advertised room with its current AirPlay state.
    public var targets: [Target] {
        lock.withLock {
            households.flatMap { id, hh in
                hh.sortedRooms.map { room in
                    let state: String = switch states[room.primary] {
                    case .connected: "connected"
                    case let .failed(reason): "failed: \(reason)"
                    case .advertising: "advertising"
                    case nil: "starting"
                    }
                    return Target(primary: room.primary, name: room.name, household: id,
                                  coordinatorIP: hh.coordinator(of: room)?.ip ?? "", state: state)
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// The room for a name (case-insensitive) or primary uuid.
    public func room(_ nameOrPrimary: String) -> Target? {
        targets.first { $0.primary == nameOrPrimary }
            ?? targets.first { $0.name.caseInsensitiveCompare(nameOrPrimary) == .orderedSame }
    }

    // MARK: - Multi-room

    /// Also plays the sender of room `source` in `room`, even across S1/S2 systems.
    public func link(_ room: String, to source: String) async throws {
        guard let coordinator = coordinator(forRoom: room) else { throw SonosError.notFound(room) }
        try await bridge.link(room, to: source, coordinatorIP: coordinator.ip,
                              title: title(roomName(room)), legacy: coordinator.isLegacyStreamer)
    }

    /// Stops an extra room started by `link`.
    public func unlink(_ room: String) async { await bridge.unlink(room) }

    /// Delays one room's output (0…2000 ms) to line up rooms on different systems.
    public func setDelay(_ room: String, ms: Int) { bridge.setDelay(room, ms: ms) }

    // MARK: - Wiring

    private func wire() {
        receiver.onState = { [weak self] primary, state in
            guard let self else { return }
            self.lock.withLock { self.states[primary] = state }
            // Back to advertising means the sender left: tear its rooms down.
            switch state {
            case .advertising, .failed: Task { await self.bridge.end(primary) }
            case .connected: break
            }
        }
        receiver.onFormat = { [weak self] primary, format in
            guard let self, let coordinator = self.coordinator(forRoom: primary) else {
                log.error("AirPlay hub: no coordinator for \(primary, privacy: .public)")
                return
            }
            let title = self.title(self.roomName(primary))
            Task {
                await self.bridge.begin(primary, format: format, coordinatorIP: coordinator.ip,
                                        title: title, legacy: coordinator.isLegacyStreamer)
            }
        }
        // Straight off the RTP thread: no hops on the audio path.
        receiver.onAudio = { [weak self] primary, pcm in self?.bridge.feed(primary, pcm) }
        receiver.onVolume = { [weak self] primary, db in
            guard let self else { return }
            // Every room this sender plays in follows the buttons, each from its own level.
            for room in self.bridge.rooms(fedBy: primary) {
                guard let ip = self.volumeDevice(forRoom: room)?.ip else { continue }
                Task { await self.bridge.volume(room, senderDB: db, ip: ip) }
            }
        }
    }

    private func coordinator(forRoom primary: String) -> Device? {
        lock.withLock {
            for hh in households.values {
                if let room = hh.rooms[primary], let d = hh.coordinator(of: room), !d.ip.isEmpty { return d }
            }
            return nil
        }
    }

    /// The room's own primary player; its volume is the room's volume.
    private func volumeDevice(forRoom primary: String) -> Device? {
        let own = lock.withLock { households.values.lazy.compactMap { $0.devices[primary] }.first { !$0.ip.isEmpty } }
        return own ?? coordinator(forRoom: primary)
    }

    private func roomName(_ primary: String) -> String {
        lock.withLock { households.values.lazy.compactMap { $0.rooms[primary]?.name }.first } ?? primary
    }
}
