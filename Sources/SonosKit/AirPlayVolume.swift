import Foundation

/// AirPlay sender volume (`SET_PARAMETER volume: <dB>`) and how it moves a Sonos room.
///
/// The mapping is anchored, not absolute: the first volume a sender reports (sent as it
/// connects) only records a baseline against the room's current level, so connecting never
/// jumps the room's volume. From there the phone's remaining travel maps onto the room's
/// remaining range — phone at maximum is room 100, phone at minimum is room 0.
public struct AirPlayVolume: Sendable, Equatable {
    let senderBase: Double
    let roomBase: Int

    public init(senderDB: Double, roomVolume: Int) {
        senderBase = Self.fraction(senderDB)
        roomBase = min(100, max(0, roomVolume))
    }

    /// The room volume for a new sender level, clamped to 0…100.
    public func roomVolume(forSenderDB db: Double) -> Int {
        let f = Self.fraction(db)
        let room = Double(roomBase)
        let value: Double
        if f >= senderBase {
            value = senderBase >= 1 ? room : room + (f - senderBase) / (1 - senderBase) * (100 - room)
        } else {
            value = senderBase <= 0 ? room : room * f / senderBase
        }
        return min(100, max(0, Int(value.rounded())))
    }

    /// AirPlay dB (-30…0, -144 = mute) as 0…1.
    static func fraction(_ db: Double) -> Double {
        db <= -30 ? 0 : min(1, (db + 30) / 30)
    }

    /// Reads the dB value from a `text/parameters` body such as "volume: -11.250000\r\n".
    public static func parse(_ body: String) -> Double? {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "volume" else { continue }
            return Double(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
