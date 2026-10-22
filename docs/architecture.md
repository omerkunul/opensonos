# Architecture

SonosKit talks to the speakers directly: UPnP/SOAP over HTTP on port 1400. There is no cloud
API and no account. Every file in `Sources/SonosKit` is one layer:

| File | Layer |
|---|---|
| `SOAP.swift` | `SOAPClient`: one SOAP call per method, UPnP faults surfaced as `UPnPError` (code 800 = not ready yet, 402 = rejected) |
| `Discovery.swift` | SSDP multicast plus a /24 scan on port 1400, merged; devices grouped into systems by household id |
| `Topology.swift` | `ZoneGroupState` parsed into `Household` → `Room` → `Device`, with `Role` and channel tokens |
| `Playback.swift` | Now playing, next/previous, TV input, grouping (`join`/`leave`), group coordinator lookup |
| `Control.swift` | Volume, mute, bass/treble/loudness, home-theater EQ (`EQType`) |
| `Planner.swift` | Pure function: current `Household` + desired layout → ordered `[Step]` |
| `Bonding.swift` | `Bonder`: runs steps, waits for the topology to settle after each, retries 800, restores surround EQ |
| `Backups.swift` | `BackupStore`: JSON snapshots of a household, for `Planner.restore` |
| `Streaming.swift` | `AudioServer` (endless WAV/MP3 over HTTP), `playStream` (point a coordinator at a URL) |
| `MP3Encoder.swift` + `CShine` | Live MP3 encoding for gen-1 players |
| `AirPlayReceiver.swift` | One RAOP (AirPlay 1) target per room: Bonjour, RTSP, RTP |
| `AirPlayCrypto.swift`, `AirPlayALAC.swift`, `AirPlayJitterBuffer.swift` | Decryption, ALAC decode, packet reordering |
| `AirPlayVolume.swift` | Sender dB → relative room volume |
| `AirPlayBridge.swift` | Sender PCM → `AudioServer` → room, multi-room `link`, per-room delay |
| `AirPlayHub.swift` | All of the above wired together for every room on the network |

## Systems, rooms, devices

A Sonos *household* is one system. S1 and S2 are always separate households and cannot be
grouped with each other. `Discovery.systems` returns one `System` per household; load each
one with `client.loadHousehold(system.seed)`.

- `Household.devices` is keyed by device uuid (`RINCON_…`).
- `Household.rooms` is keyed by the room's primary device uuid. A room is one speaker, a
  stereo pair or a home theater (`RoomKind`).
- `Household.groups` holds the play groups. Transport commands go to the group
  **coordinator** (`hh.coordinator(of: room)`). Volume goes to the room's own primary device.

Topology changes only through `Bonder` (bonding) and `join`/`leave` (grouping). Everything
else is read-only, and a refresh is one `GetZoneGroupState` call (`client.refresh(ip, keeping:)`).

## Design rules

- **Plan, then act.** `Planner` never touches the network, so any layout change can be shown
  to a person, tested, or diffed before anything happens (see `Tests/SonosKitTests/TopologyTests.swift`).
- **Wait for the real state.** Every bonding write waits until `ZoneGroupState` shows the
  expected result before the next step. A device can briefly vanish from the member list
  while it rebonds; that counts as "not yet", never as done.
- **No surprise playback.** Nothing starts playing unless a caller asks for it. The AirPlay
  bridge only reacts to a real sender choosing a room.
- **Volume is relative.** An AirPlay sender connecting never jumps a room's level.
