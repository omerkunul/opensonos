# OpenSonos

The core of a Sonos controller, in Swift, with no app attached. Two things it does that the
official app can't:

- **Any speaker as a satellite.** Bond any Sonos speaker to a soundbar as sub, rear *or front*
  left/right (for example two Play:1s as fronts). The soundbar can be an old Playbar.
- **Every room as an AirPlay target, S1 included.** Each room shows up on its own in the
  AirPlay menu of an iPhone or Mac, including S1-only and gen-1 players that never had
  AirPlay. One sender can play in rooms on different systems (S1 + S2) at the same time.

It also ships an **MCP server**, so an AI assistant (Claude Code, Claude Desktop, or any MCP
client) can list rooms, plan a satellite layout and run the AirPlay bridge.

There are no apps in this repo. It is the logic, as a SwiftPM package you can drop into
your own project.

| Product | What it is |
|---|---|
| `SonosKit` | Library: discovery, topology, bonding planner and runner, transport/volume/EQ, backups, AirPlay receiver and bridge |
| `opensonos-mcp` | MCP server on stdio |
| `opensonos` | Command line: `discover`, `airplay` |

Requires macOS 15 / iOS 18 and Swift 6. Everything talks to the speakers directly on the
local network (UPnP on port 1400). No cloud, no account.

## Quick start

```sh
swift build -c release
.build/release/opensonos discover       # list systems, rooms, devices, roles
.build/release/opensonos airplay        # every room appears in the AirPlay menu
```

As a library:

```swift
.package(url: "https://github.com/omerkunul/opensonos.git", branch: "main")
// target dependency: .product(name: "SonosKit", package: "opensonos")
```

```swift
import SonosKit

let client = SOAPClient()
let systems = await Discovery.systems(await Discovery.discover(client: client))
let hh = try await client.loadHousehold(systems[0].seed)

// Two Play:1s as front left/right of the Playbar, Sub kept:
let bar = hh.rooms.values.first { $0.kind == .homeTheater }!.primary
let steps = Planner.layout(hh, bar: bar, assignments: [
    subUUID: .sub, leftUUID: .frontLeft, rightUUID: .frontRight,
])
for step in steps { print(step.describe(hh)) }        // read-only so far
try BackupStore().save(hh, label: "before fronts")    // always back up first
_ = try await Bonder(client: client).run(steps, on: hh)
```

```swift
// AirPlay for every room, as long as the process runs:
let hub = AirPlayHub()
await hub.refresh()
hub.keepFresh()
```

## Docs

- [Architecture](docs/architecture.md): how the pieces fit
- [Adding satellites](docs/satellites.md): channel tokens, the planner, the bonding quirks
- [AirPlay to Sonos](docs/airplay.md): RAOP receiver, decryption, ALAC, re-streaming, gen-1 MP3
- [MCP server](docs/mcp.md): setup and tools

## Safety

Bonding rebuilds a home theater. Speakers drop out for a few seconds while they rebond,
and the bar's surround settings get reset; the bonder restores them afterwards. Save a
`BackupStore` snapshot first so `Planner.restore` can put things back. The MCP tools do
that for you, refuse to bond without `confirm: true`, and cap volume at
`OPENSONOS_MAX_VOLUME`.

## License

MIT, see [LICENSE](LICENSE). `Sources/CShine` is the shine MP3 encoder under LGPL v2; see
[NOTICE](NOTICE).

Not affiliated with or endorsed by Sonos, Inc. or Apple Inc. "Sonos" and "AirPlay" are
trademarks of their owners and are used here only to describe compatibility.
