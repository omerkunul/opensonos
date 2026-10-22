import Foundation
import OSLog

private let log = Logger(subsystem: "opensonos", category: "airplay-bridge")

/// Re-streams a connected AirPlay sender's decoded audio to its Sonos room: it holds one WAV
/// server per active room, tells the room's coordinator to play that server's URL when a sender
/// connects, and forwards the decoded PCM to it. The audio path (`feed`) runs straight off the
/// RTP thread with no main-actor hop, so it does not stall per packet; the play/stop control
/// path is async and serialized per room.
///
/// One sender can be fanned out to more rooms (`link`): each extra room gets its own server fed
/// the same PCM, so a phone playing to Kitchen can also play in Living Room even though the two
/// rooms sit in different Sonos systems. Each room has its own output delay to line them up.
///
/// This bridge only reacts to a *real* sender connecting — the listener picks the room in the system
/// AirPlay menu. It never starts playback on its own.
public final class AirPlayBridge: @unchecked Sendable {
    private struct Room {
        let server: AudioServer
        let coordinatorIP: String
        let port: UInt16
        /// The AirPlay target (room primary) whose sender feeds this room.
        let source: String
        var delayMs = 0
    }

    /// A bridged room as the UI sees it.
    public struct Link: Equatable, Sendable {
        public let room: String
        public let source: String
        public let delayMs: Int
    }

    private let lock = NSLock()
    private var rooms: [String: Room] = [:]
    /// Formats of live senders by target primary, so extra rooms can be started later.
    private var formats: [String: AirPlayAudioFormat] = [:]
    private let net = SOAPClient(timeout: 20)
    /// Sender volume last applied to each room; the first report of a session only sets it.
    private var senderDB: [String: Double] = [:]
    /// Latest sender volume not yet applied, so a burst of button presses coalesces.
    private var pendingDB: [String: Double] = [:]
    private var volumeBusy: Set<String> = []
    /// Held while any room is bridged, so App Nap never throttles the real-time audio path
    /// when the app sits in the background.
    private var activity: NSObjectProtocol?
    /// Called (on any thread) whenever the set of bridged rooms changes.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Takes or releases the no-nap activity to match whether any room is live. Call under `lock`.
    private func updateActivity() {
        if rooms.isEmpty, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        } else if !rooms.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Streaming AirPlay audio to Sonos")
        }
    }

    /// Every bridged room with the sender feeding it.
    public var links: [Link] {
        lock.withLock { rooms.map { Link(room: $0.key, source: $0.value.source, delayMs: $0.value.delayMs) } }
    }

    /// Target primaries with a live sender.
    public var sources: [String] { lock.withLock { Array(formats.keys) } }

    /// A sender connected to `primary`; start a WAV server and point the coordinator at it.
    /// `coordinatorIP` is the room's group coordinator, resolved by the caller.
    public func begin(_ primary: String, format: AirPlayAudioFormat, coordinatorIP ip: String, title: String,
               legacy: Bool = false) async {
        lock.withLock { formats[primary] = format }
        await start(primary, source: primary, coordinatorIP: ip, title: title, legacy: legacy)
    }

    /// Also plays the sender of `source` in `room`. Fails if that sender is gone.
    public func link(_ room: String, to source: String, coordinatorIP ip: String, title: String, legacy: Bool) async throws {
        guard lock.withLock({ formats[source] != nil }) else {
            throw SonosError.invalid("That AirPlay stream has ended.")
        }
        if let error = await start(room, source: source, coordinatorIP: ip, title: title, legacy: legacy) { throw error }
    }

    /// Stops an extra room; the sender's own room is stopped only when the sender leaves.
    public func unlink(_ room: String) async {
        await stop(room)
    }

    /// Delays one bridged room's output (0…2000 ms) so rooms in different systems line up.
    public func setDelay(_ room: String, ms: Int) {
        let clamped = max(0, min(ms, 2_000))
        let server = lock.withLock { () -> AudioServer? in
            rooms[room]?.delayMs = clamped
            return rooms[room]?.server
        }
        server?.setOutputDelay(ms: clamped)
        onChange?()
    }

    @discardableResult
    private func start(_ room: String, source: String, coordinatorIP ip: String, title: String, legacy: Bool) async -> Error? {
        // A second ANNOUNCE for a room already live: reuse the running server.
        if lock.withLock({ rooms[room] != nil }) { return nil }
        guard let format = lock.withLock({ formats[source] }) else { return nil }

        let server = AudioServer()
        do {
            let port = try await server.start(sampleRate: format.sampleRate, channels: format.channels)
            guard let host = LocalAddress.ipv4(near: ip) else {
                server.stop()
                throw SonosError.invalid("This Mac has no address on that room's network.")
            }
            lock.withLock { rooms[room] = Room(server: server, coordinatorIP: ip, port: port, source: source); updateActivity() }
            onChange?()
            let url = "http://\(host):\(port)\(legacy ? AudioServer.mp3Path : AudioServer.path)"
            try await net.playStream(ip, url: url, title: title, format: legacy ? .mp3 : .wav)
            log.info("AirPlay bridge live for \(room, privacy: .public) from \(source, privacy: .public) -> \(url, privacy: .public)")
            return nil
        } catch {
            log.error("AirPlay bridge start for \(room, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            server.stop()
            lock.withLock { rooms[room] = nil; updateActivity() }
            onChange?()
            return error
        }
    }

    /// Forwards decoded PCM to every room fed by this sender. Called on the RTP thread; cheap and lock-guarded.
    public func feed(_ source: String, _ pcm: Data) {
        let servers = lock.withLock { rooms.values.filter { $0.source == source }.map(\.server) }
        for server in servers { server.send(pcm) }
    }

    /// The sender for `primary` went away: stop every room it fed and tell their coordinators to stop.
    public func end(_ primary: String) async {
        let fed = lock.withLock { () -> [String] in
            formats[primary] = nil
            return rooms.filter { $0.value.source == primary }.map(\.key)
        }
        for room in fed { await stop(room) }
    }

    private func stop(_ key: String) async {
        let room = lock.withLock { () -> Room? in
            let r = rooms[key]; rooms[key] = nil
            senderDB[key] = nil; pendingDB[key] = nil
            updateActivity()
            return r
        }
        guard let room else { return }
        onChange?()
        room.server.stop()
        try? await net.stop(room.coordinatorIP)
        log.info("AirPlay bridge ended for \(key, privacy: .public)")
    }

    /// Rooms fed by the sender of `source`, the sender's own room first.
    public func rooms(fedBy source: String) -> [String] {
        lock.withLock {
            rooms.filter { $0.value.source == source }.map(\.key).sorted { ($0 == source ? 0 : 1) < ($1 == source ? 0 : 1) }
        }
    }

    /// The sender changed its volume. The first report of a session (sent as it connects) only
    /// records where the phone's slider sits; later ones move the room's volume by the same
    /// relative amount from wherever it is now, so connecting never jumps the room's level and
    /// a change made in the Sonos app in between is respected.
    public func volume(_ primary: String, senderDB db: Double, ip: String) async {
        let start = lock.withLock { () -> Bool in
            guard senderDB[primary] != nil else { senderDB[primary] = db; return false }
            pendingDB[primary] = db
            return volumeBusy.insert(primary).inserted
        }
        guard start else { return }
        while let next = lock.withLock({ () -> (Double, Double)? in
            guard let target = pendingDB.removeValue(forKey: primary), let last = senderDB[primary] else {
                volumeBusy.remove(primary); return nil
            }
            return (last, target)
        }) {
            let current: Int
            do { current = try await net.volume(ip) } catch {
                log.error("AirPlay volume read from \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let value = AirPlayVolume(senderDB: next.0, roomVolume: current).roomVolume(forSenderDB: next.1)
            if value != current { try? await net.setVolume(ip, value) }
            lock.withLock { if senderDB[primary] != nil { senderDB[primary] = next.1 } }
            log.notice("AirPlay volume for \(primary, privacy: .public): \(current) -> \(value)")
        }
    }

    /// True while a sender is bridged to `primary`.
    public func isLive(_ primary: String) -> Bool {
        return lock.withLock { rooms[primary] != nil }
    }
}
