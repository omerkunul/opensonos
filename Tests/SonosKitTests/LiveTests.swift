import Foundation
import Testing
@testable import SonosKit

/// Live network: only with OPENSONOS_LIVE=1, read-only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSONOS_LIVE"] == "1"))
func liveReadOnly() async throws {
    let ssdp = await Task.detached { Discovery.ssdp(timeout: 2) }.value
    print("SSDP:", ssdp)
    print("Local IP:", Discovery.localIPv4() ?? "-")
    let ips = await Discovery.discover()
    print("Discovery:", ips)
    let systems = await Discovery.systems(ips)
    for s in systems { print("System", s.id, s.ips) }
    let s = try #require(systems.first)
    let hh = try await SOAPClient().loadHousehold(s.seed)
    for r in hh.sortedRooms {
        print("■", r.name, r.kind, hh.members(of: r).map { "\($0.role.label)=\($0.model)" })
        if let c = hh.coordinator(of: r), let np = try? await SOAPClient().nowPlaying(c.ip) {
            print("  ▶", np.state, np.source, np.title, np.artist)
        }
    }
}
