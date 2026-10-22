import Foundation
import SonosKit

// opensonos: a small command line for the SonosKit core.
//
//   opensonos discover    list every Sonos system, room and device
//   opensonos airplay     advertise every room as an AirPlay target until Ctrl-C

let usage = """
usage: opensonos discover
       opensonos airplay
"""

switch CommandLine.arguments.dropFirst().first {
case "discover":
    let client = SOAPClient()
    let systems = await Discovery.systems(await Discovery.discover(client: client))
    if systems.isEmpty { print("No Sonos devices found."); exit(1) }
    for system in systems {
        print("System \(system.id)")
        guard let hh = try? await client.loadHousehold(system.seed) else { print("  (not reachable)"); continue }
        for room in hh.sortedRooms {
            print("  \(room.name) [\(room.kind.rawValue)]")
            for d in hh.members(of: room) {
                print("    \(d.displayModel)  \(d.ip)  \(d.role.label)  \(d.uuid)")
            }
        }
    }

case "airplay":
    let hub = AirPlayHub()
    await hub.refresh()
    hub.keepFresh()
    for target in hub.targets { print("AirPlay target: \(target.name)") }
    if hub.targets.isEmpty { print("No rooms yet; still looking every minute.") }
    print("Pick a room in the AirPlay menu of any Apple device. Ctrl-C to stop.")

    // Ctrl-C ends the bridged streams so the rooms stop cleanly.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        Task {
            await hub.stop()
            exit(0)
        }
    }
    interrupt.resume()
    while true { try await Task.sleep(for: .seconds(3600)) }

default:
    print(usage)
    exit(2)
}
