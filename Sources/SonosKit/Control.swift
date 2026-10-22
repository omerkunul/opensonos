import Foundation

/// Volume, EQ and playback controls. Satellites answer tone/EQ calls with 803;
/// their sound is controlled through the bar.
public enum EQType: String, CaseIterable, Sendable, Codable {
    case nightMode = "NightMode"
    case dialogLevel = "DialogLevel"
    case subGain = "SubGain"
    case subEnabled = "SubEnabled"
    case surroundEnable = "SurroundEnable"
    case surroundLevel = "SurroundLevel"
    case musicSurroundLevel = "MusicSurroundLevel"
    case surroundMode = "SurroundMode"
    case heightChannelLevel = "HeightChannelLevel"

    /// Settings the bar resets on rebonding, written back afterwards.
    public static let surroundKeys: [EQType] = [.surroundEnable, .surroundLevel, .musicSurroundLevel,
                                                .surroundMode, .subGain, .heightChannelLevel]
}

public struct Tone: Sendable, Equatable {
    public var volume = 0, bass = 0, treble = 0
    public var mute = false, loudness = false
}

public extension SOAPClient {
    private static let instance = ("InstanceID", "0")
    private static let master = ("Channel", "Master")

    func tone(_ ip: String) async throws -> Tone {
        async let v = call(ip, .renderingControl, "GetVolume", [Self.instance, Self.master])
        async let m = call(ip, .renderingControl, "GetMute", [Self.instance, Self.master])
        async let b = call(ip, .renderingControl, "GetBass", [Self.instance])
        async let t = call(ip, .renderingControl, "GetTreble", [Self.instance])
        async let l = call(ip, .renderingControl, "GetLoudness", [Self.instance, Self.master])
        return try await Tone(volume: Int(v["CurrentVolume"] ?? "") ?? 0,
                              bass: Int(b["CurrentBass"] ?? "") ?? 0,
                              treble: Int(t["CurrentTreble"] ?? "") ?? 0,
                              mute: m["CurrentMute"] == "1",
                              loudness: l["CurrentLoudness"] == "1")
    }

    /// The player's current master volume (0…100).
    func volume(_ ip: String) async throws -> Int {
        let r = try await call(ip, .renderingControl, "GetVolume", [Self.instance, Self.master])
        return Int(r["CurrentVolume"] ?? "") ?? 0
    }

    func setVolume(_ ip: String, _ value: Int) async throws {
        _ = try await call(ip, .renderingControl, "SetVolume",
                           [Self.instance, Self.master, ("DesiredVolume", String(min(100, max(0, value))))])
    }

    func setMute(_ ip: String, _ on: Bool) async throws {
        _ = try await call(ip, .renderingControl, "SetMute", [Self.instance, Self.master, ("DesiredMute", on ? "1" : "0")])
    }

    func setBass(_ ip: String, _ value: Int) async throws {
        _ = try await call(ip, .renderingControl, "SetBass", [Self.instance, ("DesiredBass", String(min(10, max(-10, value))))])
    }

    func setTreble(_ ip: String, _ value: Int) async throws {
        _ = try await call(ip, .renderingControl, "SetTreble", [Self.instance, ("DesiredTreble", String(min(10, max(-10, value))))])
    }

    func setLoudness(_ ip: String, _ on: Bool) async throws {
        _ = try await call(ip, .renderingControl, "SetLoudness", [Self.instance, Self.master, ("DesiredLoudness", on ? "1" : "0")])
    }

    /// EQ types the device supports; unsupported ones are skipped.
    func eq(_ ip: String, _ types: [EQType] = EQType.allCases) async -> [EQType: Int] {
        await withTaskGroup(of: (EQType, Int?).self) { group in
            for t in types {
                group.addTask {
                    let r = try? await call(ip, .renderingControl, "GetEQ", [Self.instance, ("EQType", t.rawValue)])
                    return (t, r?["CurrentValue"].flatMap { Int($0) })
                }
            }
            return await group.reduce(into: [:]) { if let v = $1.1 { $0[$1.0] = v } }
        }
    }

    func setEQ(_ ip: String, _ type: EQType, _ value: Int) async throws {
        _ = try await call(ip, .renderingControl, "SetEQ", [Self.instance, ("EQType", type.rawValue), ("DesiredValue", String(value))])
    }

    /// Audio format the bar receives from the TV (GetZoneInfo.HTAudioIn).
    func tvInputFormat(_ ip: String) async throws -> (code: Int, label: String) {
        let code = Int(try await call(ip, .deviceProperties, "GetZoneInfo")["HTAudioIn"] ?? "") ?? 0
        return (code, AudioInput.label(code))
    }

    func play(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "Play", [Self.instance, ("Speed", "1")])
    }

    func pause(_ ip: String) async throws {
        _ = try await call(ip, .avTransport, "Pause", [Self.instance])
    }

    func transportState(_ ip: String) async throws -> String {
        try await call(ip, .avTransport, "GetTransportInfo", [Self.instance])["CurrentTransportState"] ?? ""
    }
}

/// HTAudioIn codes (SoCo AUDIO_INPUT_FORMATS).
public enum AudioInput {
    static let formats: [Int: String] = [
        0: "No input connected", 2: "Stereo", 7: "Dolby 2.0", 18: "Dolby 5.1", 21: "No input", 22: "No audio",
        59: "Dolby Atmos (DD+)", 61: "Dolby Atmos (TrueHD)", 63: "Dolby Atmos (MAT 2.0)",
        33554434: "PCM 2.0", 33554454: "PCM 2.0 (no audio)", 33554488: "Dolby 2.0",
        33554490: "Dolby Digital Plus 2.0", 84934658: "Multichannel PCM 5.1", 84934713: "Dolby 5.1",
        84934714: "Dolby Digital Plus 5.1", 84934721: "DTS 5.1",
    ]

    public static func label(_ code: Int) -> String { formats[code] ?? "Unknown (\(code))" }
}
