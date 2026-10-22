import Foundation

/// Finds Sonos devices on the network. SSDP first; if nothing answers (e.g. no
/// multicast entitlement on iOS) the local /24 is scanned on port 1400.
public enum Discovery {
    public struct System: Sendable, Identifiable, Hashable {
        public let id: String  // household id
        public let ips: [String]
        public var seed: String { ips.sorted(by: Self.ipLess).first ?? "" }

        static func ipLess(_ a: String, _ b: String) -> Bool {
            a.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes(
                b.split(separator: ".").compactMap { Int($0) })
        }
    }

    /// SSDP and a subnet scan are merged: S1 and S2 are separate households, and SSDP
    /// often hears only one of them, so the scan makes sure every network is found.
    public static func discover(client: SOAPClient = SOAPClient()) async -> [String] {
        async let ssdpFound = Task.detached { ssdp(timeout: 2) }.value
        var all = Set(await ssdpFound)
        if let ip = localIPv4() { all.formUnion(await scan(subnetOf: ip)) }
        return all.sorted(by: System.ipLess)
    }

    /// Groups IPs by household; S1 and S2 systems are separate households.
    /// The system with the most devices comes first.
    public static func systems(_ ips: [String], client: SOAPClient = SOAPClient(timeout: 3)) async -> [System] {
        let pairs = await withTaskGroup(of: (String, String)?.self) { group in
            for ip in ips {
                group.addTask {
                    let id = try? await client.call(ip, .deviceProperties, "GetHouseholdID")["CurrentHouseholdID"]
                    return id.map { (ip, $0) }
                }
            }
            return await group.reduce(into: [(String, String)]()) { if let p = $1 { $0.append(p) } }
        }
        let grouped = Dictionary(grouping: pairs, by: \.1).mapValues { $0.map(\.0) }
        return grouped.map { System(id: $0.key, ips: $0.value) }
            .sorted { ($0.ips.count, $1.id) > ($1.ips.count, $0.id) }
    }

    // MARK: - SSDP

    static func ssdp(timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)

        let search = Array((
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n" +
            "MX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n").utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, search, search.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            guard text.range(of: "Sonos", options: .caseInsensitive) != nil else { continue }
            found.insert(ipString(from.sin_addr))
        }
        return found.sorted(by: System.ipLess)
    }

    // MARK: - Subnet scan

    static func scan(subnetOf ip: String) async -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".")
        let client = SOAPClient(timeout: 1.5)
        return await withTaskGroup(of: String?.self) { group in
            for host in 1...254 {
                let candidate = "\(prefix).\(host)"
                group.addTask {
                    guard let data = try? await client.get(candidate, path: "/xml/device_description.xml"),
                          String(decoding: data, as: UTF8.self).contains("Sonos") else { return nil }
                    return candidate
                }
            }
            return await group.compactMap { $0 }.reduce(into: []) { $0.append($1) }
        }.sorted(by: System.ipLess)
    }

    public static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0, ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipString($0.pointee.sin_addr) }
            if String(cString: ifa.ifa_name) == "en0" { return ip }
            best = best ?? ip
        }
        return best
    }

    private static func ipString(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
