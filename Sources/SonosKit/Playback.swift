import Foundation

/// What a group coordinator is playing (GetTransportInfo + GetMediaInfo + GetPositionInfo).
public struct NowPlaying: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case tv, lineIn, radio, queue, grouped(coordinator: String), none, other
        /// This app's stream of the Mac's audio.
        case mac
    }

    public var state = ""
    public var source: Source = .none
    public var title = ""
    public var artist = ""
    public var album = ""
    /// Album art path or absolute URL, as reported by the device.
    public var artURI = ""

    public init() {}

    public var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    public var canSkip: Bool { source == .queue }

    /// Absolute artwork URL; relative paths are served by the device itself.
    public func artURL(device ip: String) -> URL? {
        guard !artURI.isEmpty else { return nil }
        if artURI.hasPrefix("http") { return URL(string: artURI) }
        return URL(string: "http://\(ip):\(SOAPClient.port)\(artURI.hasPrefix("/") ? "" : "/")\(artURI)")
    }

    static func source(_ uri: String) -> Source {
        if uri.isEmpty { return .none }
        if uri.hasPrefix("x-sonos-htastream:") { return .tv }
        // The Mac stream can be raw WAV or, for gen-1 players, MP3 over x-rincon-mp3radio — both
        // are our own stream, so match either path before the generic radio check below.
        if uri.contains(AudioServer.path) || uri.contains(AudioServer.mp3Path) { return .mac }
        if uri.hasPrefix("x-rincon-stream:") { return .lineIn }
        if uri.hasPrefix("x-rincon:") { return .grouped(coordinator: String(uri.dropFirst("x-rincon:".count))) }
        if uri.hasPrefix("x-rincon-queue:") { return .queue }
        if uri.hasPrefix("x-sonosapi-stream:") || uri.hasPrefix("x-sonosapi-radio:") || uri.hasPrefix("x-rincon-mp3radio:")
            || uri.hasPrefix("aac:") || uri.hasPrefix("hls-radio:") { return .radio }
        return .other
    }

    /// Fills title/artist/album/art from a DIDL-Lite fragment; "NOT_IMPLEMENTED" and empty input are ignored.
    mutating func apply(didl: String?) {
        guard let didl, didl.hasPrefix("<"), let root = try? XNode.parse(didl),
              let item = root.descendants("item").first else { return }
        func v(_ tag: String) -> String { item.first(tag)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        // Radio puts the current song in streamContent ("Artist - Title").
        let stream = v("streamContent")
        if !stream.isEmpty, !stream.hasPrefix("ZPSTR_") {
            let parts = stream.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = parts[0]
                title = parts.dropFirst().joined(separator: " - ")
            } else {
                title = stream
            }
        }
        if title.isEmpty { title = v("title") }
        if artist.isEmpty { artist = v("creator") }
        if album.isEmpty { album = v("album") }
        if artURI.isEmpty { artURI = v("albumArtURI") }
    }

    static func parse(state: String, mediaURI: String, mediaMeta: String?, trackURI: String, trackMeta: String?) -> NowPlaying {
        var np = NowPlaying()
        np.state = state
        np.source = source(mediaURI.isEmpty ? trackURI : mediaURI)
        np.apply(didl: trackMeta)
        // Stations keep the station name in the media metadata.
        if np.source == .radio, np.album.isEmpty {
            var media = NowPlaying()
            media.apply(didl: mediaMeta)
            np.album = media.title
        }
        if np.source == .tv { np.title = "TV" }
        if np.source == .mac { np.title = "Mac" }
        if np.source == .lineIn, np.title.isEmpty { np.title = "Line-In" }
        return np
    }
}

public extension SOAPClient {
    private static let instance = ("InstanceID", "0")

    func nowPlaying(_ ip: String) async throws -> NowPlaying {
        async let t = call(ip, .avTransport, "GetTransportInfo", [Self.instance])
        async let m = call(ip, .avTransport, "GetMediaInfo", [Self.instance])
        async let p = call(ip, .avTransport, "GetPositionInfo", [Self.instance])
        let (transport, media, position) = try await (t, m, p)
        return NowPlaying.parse(state: transport["CurrentTransportState"] ?? "",
                                mediaURI: media["CurrentURI"] ?? "", mediaMeta: media["CurrentURIMetaData"],
                                trackURI: position["TrackURI"] ?? "", trackMeta: position["TrackMetaData"])
    }

    func next(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "Next", [Self.instance])
    }

    func previous(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "Previous", [Self.instance])
    }

    /// Switches a home theater bar to its TV input.
    func switchToTV(_ ip: String, bar uuid: String) async throws {
        _ = try await call(ip, .avTransport, "SetAVTransportURI",
                           [Self.instance, ("CurrentURI", "x-sonos-htastream:\(uuid):spdif"), ("CurrentURIMetaData", "")])
    }

    /// Makes the room at `ip` follow the group of `coordinator`.
    func join(_ ip: String, coordinator uuid: String) async throws {
        _ = try await call(ip, .avTransport, "SetAVTransportURI",
                           [Self.instance, ("CurrentURI", "x-rincon:\(uuid)"), ("CurrentURIMetaData", "")])
    }

    /// Takes the room at `ip` out of its group.
    func leave(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "BecomeCoordinatorOfStandaloneGroup", [Self.instance])
    }
}

public extension Household {
    /// The group a room is in.
    func group(of room: Room) -> Group? { groups.first { $0.rooms.contains(room.primary) } }

    /// The coordinator's device for a room: playback commands go there.
    func coordinator(of room: Room) -> Device? {
        group(of: room).flatMap { devices[$0.coordinator] } ?? devices[room.primary]
    }

    /// Other rooms that play together with this one.
    func groupmates(of room: Room) -> [Room] {
        (group(of: room)?.rooms ?? []).filter { $0 != room.primary }.compactMap { rooms[$0] }
    }
}
