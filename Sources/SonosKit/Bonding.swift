import Foundation

/// Runs bonding steps. After each write it waits until the topology settles
/// into the expected state, so the next step never builds on a half-applied one.
public struct Bonder: Sendable {
    public let client: SOAPClient
    public var waitTimeout: Duration = .seconds(60)

    public init(client: SOAPClient = SOAPClient()) { self.client = client }

    public enum Event: Sendable {
        case started(Int, String)
        case retrying(String)
        case finished(Int)
        case restoredEQ(String)
    }

    /// Runs the steps in order. Rebonding resets the bar's surround EQ, so the
    /// affected bars' settings are read first and written back at the end.
    public func run(_ steps: [Step], on start: Household,
                    progress: @Sendable (Event) async -> Void = { _ in }) async throws -> Household {
        let bars = Set(steps.compactMap { s -> String? in
            if case let .addSatellite(bar, _, _) = s { return bar }
            if case let .removeSatellite(u) = s { return start.devices[u]?.bondedTo }
            return nil
        })
        var savedEQ: [String: [EQType: Int]] = [:]
        for bar in bars { if let ip = start.devices[bar]?.ip { savedEQ[ip] = await client.eq(ip, EQType.surroundKeys) } }

        var hh = start
        for (i, step) in steps.enumerated() {
            await progress(.started(i, step.describe(hh)))
            hh = try await execute(step, on: hh, progress: progress)
            await progress(.finished(i))
        }

        for (ip, values) in savedEQ where !values.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            let now = await client.eq(ip, EQType.surroundKeys)
            for (type, value) in values where now[type] != value {
                try? await client.setEQ(ip, type, value)
            }
            await progress(.restoredEQ(ip))
        }
        return hh
    }

    public func execute(_ step: Step, on hh: Household,
                        progress: @Sendable (Event) async -> Void = { _ in }) async throws -> Household {
        func dev(_ u: String) throws -> Device {
            guard let d = hh.devices[u] else { throw SonosError.notFound(u) }
            return d
        }
        switch step {
        case let .createPair(left, right):
            let l = try dev(left)
            let map = ChannelMap.format([(left, "LF,LF"), (right, "RF,RF")])
            _ = try await client.call(l.ip, .deviceProperties, "CreateStereoPair", [("ChannelMapSet", map)])
            return try await wait(l.ip, hh) { $0.devices[right]?.bondedTo == left }

        case let .separatePair(primary):
            guard let room = hh.rooms[primary], room.kind == .stereoPair else {
                throw SonosError.invalid("\(primary) is not a stereo pair")
            }
            let p = try dev(primary)
            _ = try await client.call(p.ip, .deviceProperties, "SeparateStereoPair", [("ChannelMapSet", room.pairMapString)])
            let others = room.pairMap.keys.filter { $0 != primary }
            return try await wait(p.ip, hh) { h in others.allSatisfy { h.devices[$0]?.bondedTo == "" } }

        case let .removeSatellite(uuid):
            let s = try dev(uuid)
            guard !s.bondedTo.isEmpty else { return hh }
            let bar = try dev(s.bondedTo)
            _ = try await client.call(bar.ip, .deviceProperties, "RemoveHTSatellite", [("SatRoomUUID", uuid)])
            return try await wait(bar.ip, hh) { $0.devices[uuid]?.bondedTo == "" }

        case let .addSatellite(barUUID, uuid, token):
            let bar = try dev(barUUID)
            // Keep the bar token: the Playbar reverts "CC" after ~1 min, "LF,RF" sticks.
            let barToken = ChannelMap.barTokens.contains(bar.channel) ? bar.channel : "LF,RF"
            // Firmware may expand a token (LF -> "LF,LTF"); only the first token is sent.
            let map = ChannelMap.format([(barUUID, barToken), (uuid, ChannelMap.firstToken(token))])
            try await addHTSatellite(bar.ip, map, progress: progress)
            return try await wait(bar.ip, hh) { $0.devices[uuid]?.bondedTo == barUUID }
        }
    }

    /// One satellite per call. 800 usually means the device hasn't settled yet
    /// (3-15 s after unbonding); retried for 30 s. 402 is a real rejection.
    func addHTSatellite(_ ip: String, _ map: String, progress: @Sendable (Event) async -> Void) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while true {
            do {
                _ = try await client.call(ip, .deviceProperties, "AddHTSatellite", [("HTSatChanMapSet", map)])
                return
            } catch let e as UPnPError where e.code == 800 && ContinuousClock.now < end {
                await progress(.retrying("Device not ready (800), retrying…"))
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Waits until the topology satisfies the condition. A device can briefly drop
    /// out of the member list while bonding; the condition must treat that as "not yet".
    func wait(_ ip: String, _ old: Household, until check: (Household) -> Bool) async throws -> Household {
        let end = ContinuousClock.now + waitTimeout
        while true {
            if let hh = try? await client.refresh(ip, keeping: old), check(hh) { return hh }
            if ContinuousClock.now > end { throw SonosError.timeout("Topology did not reach the expected state (timed out)") }
            try await Task.sleep(for: .milliseconds(1500))
        }
    }
}
