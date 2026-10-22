import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "opensonos", category: "airplay-receiver")

/// Audio format a sender negotiates in the RTSP ANNOUNCE: how to decode the RTP stream
/// that follows. Filled from the SDP's `rtpmap`/`fmtp` and any encryption keys.
public struct AirPlayAudioFormat: Sendable, Equatable {
    public var sampleRate = 44_100
    public var channels = 2
    public var bitsPerSample = 16
    /// 96 = ALAC (Apple Lossless), the usual AirPlay payload; 0 = raw L16 PCM.
    public var payloadType = 96
    /// AES-128-CBC key and IV, present only when the sender encrypts (advertised `et=1`).
    /// Unwrapping the RSA-wrapped key and decrypting the stream is the next stage.
    public var aesKeyWrapped: Data?
    public var aesIV: Data?
    /// ALAC magic cookie fields from the SDP `fmtp` line, for the decoder stage.
    public var fmtp: [Int] = []
}

/// The live connection state of one advertised AirPlay target, surfaced for the UI.
public enum AirPlayStationState: Sendable, Equatable {
    case advertising          // listed in the AirPlay menu, no sender connected
    case connected(String)    // a sender is streaming; associated value is its name
    case failed(String)
}

/// One advertised AirPlay target. It advertises a `_raop._tcp` Bonjour service so every
/// Mac, iPhone and iPad on the network lists it in the system AirPlay menu, and it runs the
/// RTSP handshake a sender performs on connecting. This stage covers discovery and the
/// control handshake (the room appears and a sender can connect); decoding the RTP audio and
/// re-streaming it to the Sonos room is wired on top of `onAudio` / `onFormat` next.
public final class AirPlayStation: @unchecked Sendable {
    public let roomPrimary: String
    public let displayName: String
    /// Stable 12-hex device id this target presents to senders (its AirPlay "MAC").
    public let deviceID: String

    /// Reports connection-state changes (advertising / a sender connected / failed).
    public var onState: (@Sendable (AirPlayStationState) -> Void)?
    /// Called once per session with the negotiated audio format from ANNOUNCE.
    public var onFormat: (@Sendable (AirPlayAudioFormat) -> Void)?
    /// Delivers decoded 16-bit little-endian interleaved PCM (wired in the decoder stage).
    public var onAudio: (@Sendable (Data) -> Void)?
    /// The sender's volume in AirPlay dB (-30…0, -144 = mute), each time the user changes it.
    public var onVolume: (@Sendable (Double) -> Void)?

    private let queue = DispatchQueue(label: "opensonos.airplay.\(UUID().uuidString)")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: RTSPSession] = [:]

    public init(roomPrimary: String, displayName: String) {
        self.roomPrimary = roomPrimary
        self.displayName = displayName
        self.deviceID = Self.deviceID(for: roomPrimary)
    }

    /// Begins advertising. The room then appears in the AirPlay menu on nearby devices.
    public func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)   // OS-assigned port; Bonjour SRV follows it
        listener.service = NWListener.Service(
            name: "\(deviceID)@\(displayName)",
            type: "_raop._tcp",
            txtRecord: NWTXTRecord(Self.txtRecord(deviceID: deviceID))
        )
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(.advertising)
            case let .failed(error): self?.onState?(.failed(error.localizedDescription))
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        log.info("Advertising AirPlay target \(self.displayName, privacy: .public) (\(self.deviceID, privacy: .public))")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for s in sessions.values { s.close() }
        sessions = [:]
    }

    private func accept(_ connection: NWConnection) {
        let session = RTSPSession(connection: connection, queue: queue, station: self)
        sessions[ObjectIdentifier(connection)] = session
        session.onClose = { [weak self] id in self?.sessions[id] = nil }
        session.start()
    }

    // MARK: - Advertisement

    /// TXT record for an ALAC/PCM receiver. `et=0,1` offers both plain and RSA/AES sessions:
    /// iOS senders pick the RSA one and verify us with the Apple-Challenge.
    static func txtRecord(deviceID: String) -> [String: String] {
        [
            "txtvers": "1",
            "ch": "2",              // channels
            "cn": "0,1",            // codecs: 0 = PCM, 1 = ALAC
            "et": "0,1",            // encryption types: 0 = none, 1 = RSA/AES
            "ek": "1",
            "sr": "44100",          // sample rate
            "ss": "16",             // sample size (bits)
            "sv": "false",
            "da": "true",
            "md": "0,1,2",          // metadata: text, artwork, progress
            "tp": "UDP",            // transport
            "vn": "65537",
            "pw": "false",          // no password
            "vs": "105.1",          // server version
            "am": "OpenSonos",      // device model shown to some senders
            "sf": "0x4",            // status flags
        ]
    }

    /// A stable 12-hex-digit id derived from the room, used as this target's AirPlay "MAC".
    static func deviceID(for roomPrimary: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in roomPrimary.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        let bytes = (0..<6).map { UInt8((hash >> (UInt64($0) * 8)) & 0xff) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - RTSP session

/// Runs the RTSP control handshake for a single connected sender over its TCP connection.
/// Audio arrives on separate UDP ports allocated in SETUP; this stage binds and drains them
/// so the sender stays connected, and the decoder stage reads the drained packets.
private final class RTSPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var station: AirPlayStation?
    private var buffer = Data()
    private var audioPorts: [NWListener] = []
    private let pipelineLock = NSLock()
    private var pipeline: AirPlayAudioPipeline?
    var onClose: (@Sendable (ObjectIdentifier) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, station: AirPlayStation) {
        self.connection = connection
        self.queue = queue
        self.station = station
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        for l in audioPorts { l.cancel() }
        audioPorts = []
        connection.cancel()
        onClose?(ObjectIdentifier(connection))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainMessages()
            }
            if isComplete || error != nil { self.close() } else { self.receive() }
        }
    }

    /// Pulls complete RTSP messages out of the buffer and answers each one.
    private func drainMessages() {
        while let (message, consumed) = RTSPMessage.parse(buffer) {
            buffer.removeFirst(consumed)
            let response = handle(message)
            let status = String(decoding: response.prefix(40), as: UTF8.self)
                .split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
            log.notice("AirPlay \(self.station?.displayName ?? "?", privacy: .public) <- \(message.method, privacy: .public) \(message.uri, privacy: .public) [ua=\(message.headers["user-agent"] ?? "-", privacy: .public) ct=\(message.headers["content-type"] ?? "-", privacy: .public) len=\(message.body.count)] -> \(status, privacy: .public)")
            if ["TEARDOWN", "FLUSH", "RECORD", "SETUP", "ANNOUNCE", "PAUSE", "POST", "GET", "GET_PARAMETER"].contains(message.method)
                || message.headers["content-type"] == "text/parameters" {
                let headers = message.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
                let body = message.headers["content-type"]?.hasPrefix("text") == true ? message.bodyText : ""
                log.notice("AirPlay detail \(message.method, privacy: .public): \(headers, privacy: .public) body=\(body, privacy: .public)")
            }
            connection.send(content: response, completion: .idempotent)
        }
    }

    private func handle(_ message: RTSPMessage) -> Data {
        let cseq = message.headers["cseq"] ?? "0"
        switch message.method {
        case "OPTIONS":
            var headers = ["Public": "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"]
            // Apple senders verify the receiver with a challenge signed by the AirPort key.
            if let challenge = message.headers["apple-challenge"],
               let response = appleResponse(to: challenge) {
                headers["Apple-Response"] = response
            }
            return RTSPMessage.response(cseq: cseq, headers: headers)
        case "ANNOUNCE":
            if let format = SDP.audioFormat(from: message.bodyText) {
                buildPipeline(format)
                station?.onFormat?(format)
                log.notice("AirPlay ANNOUNCE: payload \(format.payloadType) \(format.sampleRate)Hz ch\(format.channels) encrypted=\(format.aesKeyWrapped != nil)")
            }
            return RTSPMessage.response(cseq: cseq)
        case "SETUP":
            return setup(cseq: cseq, transport: message.headers["transport"] ?? "")
        case "RECORD":
            if let name = station?.displayName { station?.onState?(.connected(name)) }
            return RTSPMessage.response(cseq: cseq, headers: ["Audio-Latency": "11025",
                                                              "Audio-Jack-Status": "connected; type=analog"])
        case "FLUSH":
            pipelineLock.lock(); let pipeline = self.pipeline; pipelineLock.unlock()
            pipeline?.flush()
            return RTSPMessage.response(cseq: cseq)
        case "SET_PARAMETER":
            if message.headers["content-type"] == "text/parameters",
               let db = AirPlayVolume.parse(message.bodyText) {
                log.notice("AirPlay volume \(db) dB")
                station?.onVolume?(db)
            }
            return RTSPMessage.response(cseq: cseq)
        case "GET_PARAMETER", "PAUSE", "POST", "GET":
            return RTSPMessage.response(cseq: cseq)
        case "TEARDOWN":
            defer { queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.close() } }
            return RTSPMessage.response(cseq: cseq, headers: ["Connection": "close"])
        default:
            return RTSPMessage.response(cseq: cseq, status: "501 Not Implemented")
        }
    }

    /// Binds UDP ports for audio/control/timing, drains them, and echoes them back so the
    /// sender has somewhere to stream to. Decoding those packets is the decoder stage.
    private func setup(cseq: String, transport: String) -> Data {
        // Audio (RTP) arrives on the data port; decode it there. Control/timing are drained.
        let dataPort = bindUDP { [weak self] packet in self?.processAudio(packet) }
        let controlPort = bindUDP { packet in Self.logSide("control", packet) }
        let timingPort = bindUDP { packet in Self.logSide("timing", packet) }
        guard dataPort > 0, controlPort > 0, timingPort > 0 else {
            return RTSPMessage.response(cseq: cseq, status: "500 Internal Server Error")
        }
        let reply = "RTP/AVP/UDP;unicast;mode=record;server_port=\(dataPort);"
            + "control_port=\(controlPort);timing_port=\(timingPort)"
        log.notice("AirPlay SETUP sender transport: \(transport, privacy: .public)")
        return RTSPMessage.response(cseq: cseq, headers: [
            "Transport": reply,
            "Session": "1",
            "Audio-Jack-Status": "connected; type=analog",
        ])
    }

    /// Binds a UDP listener on an OS-assigned port. If `onMessage` is given, each datagram is
    /// handed to it (the audio port); otherwise datagrams are drained (control/timing ports).
    /// The listener runs on its own queue so waiting for its port here never blocks the RTSP queue.
    private func bindUDP(onMessage: (@Sendable (Data) -> Void)?) -> UInt16 {
        guard let listener = try? NWListener(using: .udp) else { return 0 }
        let udpQueue = DispatchQueue(label: "opensonos.airplay.udp")
        listener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            Self.pump(conn, onMessage: onMessage)
        }
        let ready = DispatchSemaphore(value: 0)
        let box = PortBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: box.port = listener.port?.rawValue ?? 0; ready.signal()
            case .failed: ready.signal()
            default: break
            }
        }
        listener.start(queue: udpQueue)
        _ = ready.wait(timeout: .now() + 2)
        audioPorts.append(listener)
        return box.port
    }

    /// Diagnostics: logs the RTP payload type of each control/timing datagram the sender sends.
    private static func logSide(_ port: String, _ packet: Data) {
        guard packet.count >= 2 else { return }
        let type = packet[packet.startIndex + 1] & 0x7F
        log.notice("AirPlay \(port, privacy: .public) packet type 0x\(String(type, radix: 16), privacy: .public) len=\(packet.count)")
    }

    /// Reads UDP datagrams in a loop, forwarding each to `onMessage` or discarding it. Over UDP
    /// every datagram arrives marked complete, so only an error ends the loop; cancelling on
    /// `isComplete` would drop the flow after each packet and lose most of the audio.
    private static func pump(_ conn: NWConnection, onMessage: (@Sendable (Data) -> Void)?) {
        conn.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty { onMessage?(data) }
            if error != nil { conn.cancel(); return }
            pump(conn, onMessage: onMessage)
        }
    }

    // MARK: - Audio pipeline

    /// Builds the decrypt + decode pipeline from the negotiated format. Called on the RTSP queue
    /// during ANNOUNCE, before the audio port is bound, so it is ready when packets start.
    private func buildPipeline(_ format: AirPlayAudioFormat) {
        let key = format.aesKeyWrapped.flatMap { AirPlayCrypto.unwrapAESKey($0) }
        let onAudio = station?.onAudio
        let pipeline = AirPlayAudioPipeline(format: format, aesKey: key, onAudio: onAudio)
        pipelineLock.lock(); self.pipeline = pipeline; pipelineLock.unlock()
    }

    private func processAudio(_ packet: Data) {
        pipelineLock.lock(); let pipeline = self.pipeline; pipelineLock.unlock()
        pipeline?.process(packet)
    }

    /// Signs the sender's `Apple-Challenge` with the receiver's IP and this target's id.
    private func appleResponse(to challenge: String) -> String? {
        guard let data = Data(base64Padded: challenge), let station else { return nil }
        let ip = localAddressBytes() ?? Data([0, 0, 0, 0])
        let mac = Data(hex: station.deviceID) ?? Data(count: 6)
        log.notice("AirPlay challenge answered for local address \(ip.map { String($0) }.joined(separator: "."), privacy: .public) (\(ip.count) bytes)")
        return AirPlayCrypto.appleResponse(challenge: data, ip: ip, mac: mac)
    }

    /// The raw bytes of the local end of this connection, for the challenge response: 4 bytes
    /// over IPv4, 16 over IPv6 (iOS often connects over IPv6), IPv4-mapped IPv6 unwrapped to 4.
    private func localAddressBytes() -> Data? {
        guard case let .hostPort(host, _)? = connection.currentPath?.localEndpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return address.rawValue
        case let .ipv6(address):
            if let v4 = address.asIPv4 { return v4.rawValue }
            return address.rawValue
        default:
            return nil
        }
    }
}

/// Decrypts and decodes AirPlay RTP audio packets into 16-bit little-endian interleaved PCM.
private final class AirPlayAudioPipeline: @unchecked Sendable {
    private let aesKey: Data?
    private let aesIV: Data?
    private let isALAC: Bool
    private let onAudio: (@Sendable (Data) -> Void)?
    private let lock = NSLock()
    #if canImport(AudioToolbox)
    private let decoder: ALACDecoder?
    #endif
    /// Orders packets by RTP sequence and hides Wi-Fi jitter; guarded by `lock`.
    private var jitter: AirPlayJitterBuffer
    private let framesPerPacket: Int
    private let sampleRate: Int
    /// Releases buffered packets at the stream's real-time rate, so the room gets a steady feed
    /// however bursty the Wi-Fi delivery is.
    private let pacer: DispatchSourceTimer
    private var clockStart: DispatchTime?
    private var released = 0

    init(format: AirPlayAudioFormat, aesKey: Data?, onAudio: (@Sendable (Data) -> Void)?) {
        self.aesKey = aesKey
        self.aesIV = format.aesIV
        self.onAudio = onAudio
        #if canImport(AudioToolbox)
        let decoder = format.fmtp.count >= 12
            ? ALACDecoder(fmtp: format.fmtp, sampleRate: format.sampleRate) : nil
        self.decoder = decoder
        self.isALAC = decoder != nil
        #else
        self.isALAC = false
        #endif
        framesPerPacket = max(1, format.fmtp.count >= 2 ? format.fmtp[1] : 352)
        sampleRate = max(8_000, format.sampleRate)
        let packetsPerSecond = sampleRate / framesPerPacket
        jitter = AirPlayJitterBuffer(packetBytes: framesPerPacket * max(1, format.channels) * 2,
                                     prebuffer: packetsPerSecond / 4,      // ~250 ms
                                     maxDepth: packetsPerSecond * 2)       // ~2 s
        pacer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "opensonos.airplay-pacer",
                                                                    qos: .userInteractive))
        pacer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        pacer.setEventHandler { [weak self] in self?.tick() }
        pacer.resume()
    }

    deinit {
        pacer.cancel()
        log.notice("AirPlay stream ended: \(self.jitter.lost) lost, \(self.jitter.late) late packets")
    }

    /// Emits every packet due since playback (re)started. Restarts the clock on underrun.
    private func tick() {
        var out = Data()
        lock.withLock {
            guard jitter.isPlaying else { clockStart = nil; return }
            let start = clockStart ?? { let now = DispatchTime.now(); clockStart = now; released = 0; return now }()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            let due = Int(elapsed * Double(sampleRate) / Double(framesPerPacket)) + 1
            while released < due {
                guard let pcm = jitter.pop() else { clockStart = nil; break }
                out.append(pcm)
                released += 1
            }
        }
        if !out.isEmpty { onAudio?(out) }
    }

    /// Drops buffered audio after a sender FLUSH (pause, seek, track change).
    func flush() {
        lock.withLock {
            log.notice("AirPlay FLUSH: \(self.jitter.lost) lost, \(self.jitter.late) late packets so far")
            jitter.reset(); clockStart = nil
        }
    }

    /// Strips the 12-byte RTP header, decrypts the payload if keyed, then decodes/repacks to PCM.
    func process(_ packet: Data) {
        guard packet.count > 12 else { return }
        let seq = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
        var payload = packet.subdata(in: packet.index(packet.startIndex, offsetBy: 12)..<packet.endIndex)
        if let aesKey, let aesIV { payload = AirPlayCrypto.decryptAudio(payload, key: aesKey, iv: aesIV) }
        lock.lock(); defer { lock.unlock() }
        var pcm: Data?
        #if canImport(AudioToolbox)
        if isALAC, let decoder { pcm = decoder.decode(payload) } else { pcm = Self.l16ToLittleEndian(payload) }
        #else
        pcm = Self.l16ToLittleEndian(payload)
        #endif
        if let pcm, !pcm.isEmpty { jitter.insert(seq: seq, pcm: pcm) }
    }

    /// AirPlay L16 PCM is big-endian; the WAV server wants little-endian, so swap each pair.
    static func l16ToLittleEndian(_ data: Data) -> Data {
        var out = data
        out.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 1 < bytes.count { bytes.swapAt(i, i + 1); i += 2 }
        }
        return out
    }
}

private extension Data {
    /// Decodes a hex string ("AABBCC") to bytes.
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self = Data(bytes)
    }
}

/// A Sendable box so a UDP listener's port can cross its state-handler closure.
private final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }

// MARK: - RTSP parsing (pure, unit-tested)

/// A parsed RTSP request: method, URI, lower-cased headers and an optional body.
struct RTSPMessage: Equatable {
    var method = ""
    var uri = ""
    var headers: [String: String] = [:]
    var body = Data()
    var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// Parses one complete message from the front of `data`, returning it and the number of
    /// bytes it consumed, or nil if `data` does not yet hold a full message.
    static func parse(_ data: Data) -> (RTSPMessage, Int)? {
        guard let headerEnd = range(of: Data("\r\n\r\n".utf8), in: data) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        let header = String(decoding: headerData, as: UTF8.self)
        var lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var message = RTSPMessage()
        message.method = String(parts[0])
        message.uri = String(parts[1])
        lines.removeFirst()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            message.headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = message.headers["content-length"].flatMap { Int($0) } ?? 0
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        message.body = data.subdata(in: bodyStart..<bodyEnd)
        return (message, data.distance(from: data.startIndex, to: bodyEnd))
    }

    /// Builds an RTSP/1.0 response echoing CSeq, with the given status and extra headers.
    static func response(cseq: String, status: String = "200 OK", headers: [String: String] = [:]) -> Data {
        var text = "RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\nServer: AirTunes/105.1\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static func range(of pattern: Data, in data: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let last = data.index(data.endIndex, offsetBy: -pattern.count)
        var i = data.startIndex
        while i <= last {
            if data[i..<data.index(i, offsetBy: pattern.count)].elementsEqual(pattern) {
                return i..<data.index(i, offsetBy: pattern.count)
            }
            i = data.index(after: i)
        }
        return nil
    }
}

// MARK: - SDP

/// Reads the bits of an RTSP ANNOUNCE SDP body we need to decode the audio stream.
enum SDP {
    static func audioFormat(from sdp: String) -> AirPlayAudioFormat? {
        var format = AirPlayAudioFormat()
        var sawAudio = false
        // CRLF is one Swift Character, so split on any newline grapheme, not on "\r"/"\n".
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=audio") {
                sawAudio = true
                if let pt = line.split(separator: " ").last.flatMap({ Int($0) }) { format.payloadType = pt }
            } else if line.hasPrefix("a=rtpmap:") {
                // e.g. a=rtpmap:96 AppleLossless  /  a=rtpmap:96 L16/44100/2
                let spec = line.dropFirst("a=rtpmap:".count)
                if spec.contains("/") {
                    let fields = spec.split(separator: "/")
                    if fields.count >= 2, let sr = Int(fields[1]) { format.sampleRate = sr }
                    if fields.count >= 3, let ch = Int(fields[2]) { format.channels = ch }
                }
            } else if line.hasPrefix("a=fmtp:") {
                // ALAC cookie: ... <numChannels=idx7> ... <sampleRate=last>
                format.fmtp = line.dropFirst("a=fmtp:".count).split(separator: " ").compactMap { Int($0) }
                if format.fmtp.count >= 8 { format.channels = format.fmtp[7] }
                if let sr = format.fmtp.last, format.fmtp.count >= 9 { format.sampleRate = sr }
            } else if line.hasPrefix("a=rsaaeskey:") {
                format.aesKeyWrapped = Data(base64Padded: String(line.dropFirst("a=rsaaeskey:".count)))
            } else if line.hasPrefix("a=aesiv:") {
                format.aesIV = Data(base64Padded: String(line.dropFirst("a=aesiv:".count)))
            }
        }
        return sawAudio ? format : nil
    }
}

private extension Data {
    /// AirPlay SDP base64 fields drop the trailing `=` padding; restore it before decoding.
    init?(base64Padded string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}

// MARK: - Receiver (manager)

/// Keeps one advertised AirPlay target per Sonos room, so the rooms show up individually in
/// the AirPlay menu. Call `sync(rooms:)` whenever the room list changes.
public final class AirPlayReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var stations: [String: AirPlayStation] = [:]   // keyed by room primary

    /// Reports a state change for a room's target (keyed by room primary).
    public var onState: (@Sendable (String, AirPlayStationState) -> Void)?
    /// The negotiated audio format when a sender connects (keyed by room primary).
    public var onFormat: (@Sendable (String, AirPlayAudioFormat) -> Void)?
    /// Decoded 16-bit little-endian PCM from a connected sender (keyed by room primary).
    public var onAudio: (@Sendable (String, Data) -> Void)?
    /// The sender's volume in AirPlay dB (keyed by room primary).
    public var onVolume: (@Sendable (String, Double) -> Void)?

    public init() {}

    /// Adds targets for new rooms and removes targets for rooms that are gone.
    /// `rooms` maps each room's primary to its display name.
    public func sync(rooms: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        for (primary, _) in stations where rooms[primary] == nil {
            stations[primary]?.stop()
            stations[primary] = nil
        }
        for (primary, name) in rooms where stations[primary] == nil {
            let station = AirPlayStation(roomPrimary: primary, displayName: name)
            station.onState = { [weak self] state in self?.onState?(primary, state) }
            station.onFormat = { [weak self] format in self?.onFormat?(primary, format) }
            station.onAudio = { [weak self] pcm in self?.onAudio?(primary, pcm) }
            station.onVolume = { [weak self] db in self?.onVolume?(primary, db) }
            stations[primary] = station
            do { try station.start() } catch {
                log.error("AirPlay target for \(name, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stopAll() {
        lock.lock(); defer { lock.unlock() }
        for s in stations.values { s.stop() }
        stations = [:]
    }
}
