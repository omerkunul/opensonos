import Foundation

/// A single bonding operation. Steps run in order, each after the topology settles.
public enum Step: Hashable, Sendable {
    case separatePair(primary: String)
    case removeSatellite(String)
    case createPair(left: String, right: String)
    case addSatellite(bar: String, device: String, token: String)

    public func describe(_ hh: Household) -> String {
        func name(_ u: String) -> String {
            guard let d = hh.devices[u] else { return u }
            return d.model.isEmpty ? d.room : "\(d.model) · \(d.room)"
        }
        switch self {
        case let .separatePair(p): return "Separate stereo pair: \(hh.rooms[p]?.name ?? name(p))"
        case let .removeSatellite(u): return "Unbond: \(name(u)) (\(hh.devices[u]?.role.label ?? "?"))"
        case let .createPair(l, r): return "Create stereo pair: \(name(l)) + \(name(r))"
        case let .addSatellite(_, u, t): return "Add to bar: \(name(u)) → \(Role.homeTheater(t).label)"
        }
    }
}

/// Target bonding layout: an HT map per bar plus stereo pairs.
public struct Target: Sendable {
    public var homeTheaters: [String: [String: String]]  // bar -> {uuid: kod}
    public var pairs: [[String: String]]

    public init(homeTheaters: [String: [String: String]], pairs: [[String: String]]) {
        self.homeTheaters = homeTheaters
        self.pairs = pairs
    }

    public init(_ hh: Household) {
        homeTheaters = Dictionary(uniqueKeysWithValues: hh.rooms.values.filter { $0.kind == .homeTheater }.map { ($0.primary, $0.htMap) })
        pairs = hh.rooms.values.filter { $0.kind == .stereoPair }.map(\.pairMap)
    }

    static func left(of pair: [String: String]) -> String? {
        pair.first { $0.value.hasPrefix("LF") }?.key ?? pair.keys.sorted().first
    }
}

public enum Planner {
    /// Steps from the current state to the target. Order: (1) unbond what doesn't match,
    /// (2) create stereo pairs, (3) add HT satellites as Sub → rears → fronts.
    public static func plan(_ current: Household, to target: Target) -> [Step] {
        var wantBond: [String: (String, String)] = [:]  // uuid -> (primary, token)
        for (bar, map) in target.homeTheaters {
            for (u, t) in map where u != bar { wantBond[u] = (bar, t) }
        }
        for pair in target.pairs {
            guard let left = Target.left(of: pair) else { continue }
            for (u, t) in pair where u != left { wantBond[u] = (left, t) }
        }

        var steps: [Step] = []
        for d in current.devices.values.sorted(by: { $0.uuid < $1.uuid }) where !d.bondedTo.isEmpty {
            if let want = wantBond[d.uuid], want.0 == d.bondedTo, ChannelMap.sameChannel(want.1, d.channel) { continue }
            let step: Step = current.rooms[d.bondedTo]?.kind == .stereoPair
                ? .separatePair(primary: d.bondedTo) : .removeSatellite(d.uuid)
            if !steps.contains(step) { steps.append(step) }
        }

        for pair in target.pairs {
            guard let left = Target.left(of: pair), let right = pair.keys.first(where: { $0 != left }) else { continue }
            if current.devices[right]?.bondedTo == left, !steps.contains(.separatePair(primary: left)) { continue }
            steps.append(.createPair(left: left, right: right))
        }

        for bar in target.homeTheaters.keys.sorted() {
            let sats = target.homeTheaters[bar]!.filter { $0.key != bar }
                .sorted { order($0.value) < order($1.value) }
            for (u, t) in sats {
                let cur = current.devices[u]
                let removed = steps.contains(.removeSatellite(u))
                if let cur, cur.bondedTo == bar, ChannelMap.sameChannel(cur.channel, t), !removed { continue }
                steps.append(.addSatellite(bar: bar, device: u, token: t))
            }
        }
        return steps
    }

    /// Changes a bar's satellite layout; pairs containing assigned devices are split.
    public static func layout(_ current: Household, bar: String, assignments: [String: Role]) -> [Step] {
        var target = Target(current)
        var map = [bar: current.devices[bar]?.channel ?? "LF,RF"]
        for (u, role) in assignments { if let t = role.htToken { map[u] = t } }
        let assigned = Set(map.keys)
        // An assigned device bonded to another bar is removed from it.
        target.homeTheaters = target.homeTheaters.mapValues { $0.filter { !assigned.contains($0.key) } }
        target.homeTheaters[bar] = map
        target.pairs.removeAll { !assigned.isDisjoint(with: $0.keys) }
        return plan(current, to: target)
    }

    public static func restore(_ current: Household, to snapshot: Household) -> [Step] {
        plan(current, to: Target(snapshot))
    }

    private static func order(_ token: String) -> Int {
        Role.satelliteRoles.firstIndex(of: Role.homeTheater(token)) ?? 99
    }
}
