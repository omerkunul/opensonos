import Foundation
import Network

/// Serves live PCM audio as an endless WAV file over HTTP, so a Sonos room can play it
/// like an internet radio station. Every listener gets the stream from the moment it connects.
public final class AudioServer: @unchecked Sendable {
    /// Raw 16-bit PCM wrapped in an endless WAV header; what modern Sonos players read.
    public static let path = "/opensonos/mac.wav"
    /// On-the-fly MP3, served as an internet-radio stream for gen-1 players that reject WAV.
    public static let mp3Path = "/opensonos/mac.mp3"

    private let queue = DispatchQueue(label: "opensonos.audio-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    /// Listeners taking the MP3 stream; kept apart because they share one live encoder.
    private var mp3Clients: [ObjectIdentifier: NWConnection] = [:]
    private var mp3: MP3Encoder?
    /// Set once if the encoder can't be created (unsupported rate), so we don't retry per buffer.
    private var mp3Unavailable = false
    /// Tops up the MP3 stream with silence when the Mac goes quiet, so a gen-1 player never underruns.
    private var keepalive: DispatchSourceTimer?
    /// When live PCM last arrived; drives the silence keepalive.
    private var lastFeed = DispatchTime.now()
    /// Output delay in bytes: PCM is held back this far before it reaches listeners, so two rooms
    /// playing the same Mac can be nudged into alignment by ear. 0 means no delay (immediate).
    private var delayBytes = 0
    /// Holds not-yet-delivered PCM while the delay backlog fills.
    private var delayBuffer = Data()
    private var sampleRate = 48_000
    private var channels = 2

    /// Number of connected listeners (both formats), reported on the server's queue.
    public var onListeners: (@Sendable (Int) -> Void)?

    public init() {}

    private var listenerCount: Int { clients.count + mp3Clients.count }

    /// Starts listening; returns the port. Tries `preferred` first so the URL stays stable.
    public func start(sampleRate: Int, channels: Int, preferred: UInt16 = 51_400) async throws -> UInt16 {
        stop()
        self.sampleRate = sampleRate
        self.channels = channels
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: preferred) ?? .any)
        } catch {
            return try await listen(on: .any)
        }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // State updates arrive one at a time on `queue`.
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    once.done = true
                    listener.cancel()
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            keepalive?.cancel()
            keepalive = nil
            listener?.cancel()
            listener = nil
            for c in clients.values { c.cancel() }
            for c in mp3Clients.values { c.cancel() }
            clients = [:]
            mp3Clients = [:]
            mp3 = nil
            mp3Unavailable = false
            delayBuffer = Data()
        }
    }

    /// Sets how far the stream lags real time, in milliseconds (clamped 0…2000). Used to line up
    /// two rooms playing the same Mac audio: raise the faster room until it matches the slower one.
    public func setOutputDelay(ms: Int) {
        queue.async {
            let frame = self.channels * 2
            let bytes = max(0, min(ms, 2_000)) * self.sampleRate * frame / 1_000
            self.delayBytes = (bytes / frame) * frame
        }
    }

    /// Sends 16-bit little-endian interleaved PCM to every listener: raw to WAV listeners,
    /// MP3-encoded to the radio listeners. The encoder is created on the first MP3 listener
    /// and runs only while at least one is connected.
    public func send(_ pcm: Data) {
        queue.async {
            self.lastFeed = .now()
            guard self.delayBytes > 0 else { self.broadcast(pcm); return }
            // Hold a backlog `delayBytes` deep: emit only what spills past it, keeping delivery at
            // the input rate but shifted later in time.
            self.delayBuffer.append(pcm)
            let frame = self.channels * 2
            var emit = self.delayBuffer.count - self.delayBytes
            emit -= emit % frame
            guard emit > 0 else { return }
            let chunk = Data(self.delayBuffer.prefix(emit))
            self.delayBuffer.removeFirst(emit)
            self.broadcast(chunk)
        }
    }

    /// Delivers PCM to the WAV listeners and the MP3 encoder. Call on `queue`.
    private func broadcast(_ pcm: Data) {
        for c in clients.values { c.send(content: pcm, completion: .idempotent) }
        guard !mp3Clients.isEmpty, !mp3Unavailable else { return }
        if mp3 == nil {
            do { mp3 = try MP3Encoder(sampleRate: sampleRate, channels: channels) }
            catch { mp3Unavailable = true; return }
        }
        let frames = mp3?.encode(pcm) ?? Data()
        guard !frames.isEmpty else { return }
        for c in mp3Clients.values { c.send(content: frames, completion: .idempotent) }
    }

    /// Starts the silence keepalive (idempotent); runs on `queue` once an MP3 listener is present.
    private func startKeepalive() {
        guard keepalive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pumpSilence() }
        keepalive = timer
        timer.resume()
    }

    /// Feeds the MP3 listeners encoded silence when no live PCM has arrived for a moment, so the
    /// byte stream to a gen-1 player never stalls (it would underrun and stop for good). A no-op
    /// while real audio is flowing. Runs on `queue`.
    private func pumpSilence() {
        guard !mp3Clients.isEmpty, !mp3Unavailable else { return }
        let gap = Double(DispatchTime.now().uptimeNanoseconds - lastFeed.uptimeNanoseconds) / 1_000_000_000
        guard gap >= 0.08 else { return }
        if mp3 == nil {
            do { mp3 = try MP3Encoder(sampleRate: sampleRate, channels: channels) }
            catch { mp3Unavailable = true; return }
        }
        let samples = Int(Double(sampleRate) * min(gap, 0.5)) * channels
        guard samples > 0 else { return }
        let frames = mp3?.encode(Data(count: samples * 2)) ?? Data()
        lastFeed = .now()
        guard !frames.isEmpty else { return }
        for c in mp3Clients.values { c.send(content: frames, completion: .idempotent) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            switch Self.route(request) {
            case let .head(format):
                connection.send(content: Data(Self.headers(for: format).utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            case .stream(.wav):
                connection.send(content: Data(Self.headers(for: .wav).utf8)
                                    + WAV.header(sampleRate: self.sampleRate, channels: self.channels),
                                completion: .idempotent)
                self.register(connection, mp3: false)
            case .stream(.mp3):
                connection.send(content: Data(Self.headers(for: .mp3).utf8), completion: .idempotent)
                self.register(connection, mp3: true)
            case .notFound:
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Adds `connection` to the WAV or MP3 client map and keeps the count current as it drops.
    private func register(_ connection: NWConnection, mp3: Bool) {
        let id = ObjectIdentifier(connection)
        if mp3 { mp3Clients[id] = connection; startKeepalive() } else { clients[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                if mp3 {
                    self.mp3Clients[id] = nil
                    if self.mp3Clients.isEmpty { self.keepalive?.cancel(); self.keepalive = nil }
                } else {
                    self.clients[id] = nil
                }
                self.onListeners?(self.listenerCount)
            default: break
            }
        }
        onListeners?(listenerCount)
    }

    enum Format: Equatable { case wav, mp3 }
    enum Route: Equatable { case head(Format), stream(Format), notFound }

    static func route(_ request: String) -> Route {
        let parts = request.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        guard parts.count >= 2 else { return .notFound }
        let format: Format
        if parts[1].hasPrefix(mp3Path) { format = .mp3 }
        else if parts[1].hasPrefix(path) { format = .wav }
        else { return .notFound }
        switch parts[0] {
        case "GET": return .stream(format)
        case "HEAD": return .head(format)
        default: return .notFound
        }
    }

    static func headers(for format: Format) -> String {
        """
        HTTP/1.1 200 OK\r
        Content-Type: \(format == .mp3 ? "audio/mpeg" : "audio/wav")\r
        Cache-Control: no-cache, no-store\r
        Connection: close\r
        icy-name: OpenSonos\r
        Server: OpenSonos\r
        \r

        """
    }
}

private final class Once: @unchecked Sendable { var done = false }

/// RIFF/WAVE header for 16-bit PCM of unknown length.
public enum WAV {
    public static func header(sampleRate: Int, channels: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytesPerFrame = channels * 2
        // A live stream has no end: the sizes are as large as a WAV file allows.
        let dataSize: UInt32 = 0xFFFF_FFFF - 36
        d.append(contentsOf: Array("RIFF".utf8)); u32(dataSize + 36)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * bytesPerFrame)); u16(UInt16(bytesPerFrame)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        return d
    }
}

/// This computer's IPv4 address on the speakers' network.
public enum LocalAddress {
    /// The address sharing the most leading octets with `ip`, ignoring loopback.
    public static func ipv4(near ip: String) -> String? {
        let target = ip.split(separator: ".")
        return all().max { shared($0, target) < shared($1, target) }
    }

    private static func shared(_ a: String, _ b: [Substring]) -> Int {
        zip(a.split(separator: "."), b).prefix { $0 == $1 }.count
    }

    static func all() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return out
    }
}

public extension SOAPClient {
    /// Audio stream encoding a room's coordinator should be pointed at.
    enum StreamFormat: Sendable { case wav, mp3 }

    /// Plays an HTTP audio stream on the room at `ip` (its group coordinator), titled like a station.
    ///
    /// Modern players take raw WAV over plain `http://`. Gen-1 players (e.g. the PLAY:5 S5) reject an
    /// endless WAV track and stay stopped, but will play an MP3 stream addressed with the Sonos
    /// `x-rincon-mp3radio://` scheme — the same scheme Sonos uses for internet radio.
    func playStream(_ ip: String, url: String, title: String, format: StreamFormat = .wav) async throws {
        let mime = format == .mp3 ? "audio/mpeg" : "audio/wav"
        // Radio scheme tells the player to treat the stream as an endless broadcast, not a file.
        let uri = format == .mp3 ? url.replacingOccurrences(of: "http://", with: "x-rincon-mp3radio://") : url
        let proto = format == .mp3
            ? "http-get:*:\(mime):*"
            : "http-get:*:\(mime):DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=8d700000000000000000000000000000"
        let meta = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="opensonos-mac" parentID="0" restricted="true"><dc:title>\(title)</dc:title>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        <res protocolInfo="\(proto)">\(uri)</res></item></DIDL-Lite>
        """
        _ = try await call(ip, .avTransport, "SetAVTransportURI",
                           [("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", meta)])
        try await play(ip)
    }

    func stop(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "Stop", [("InstanceID", "0")])
    }
}
