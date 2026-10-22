# AirPlay to Sonos

`AirPlayHub` makes every Sonos room show up on its own in the AirPlay menu of an iPhone,
iPad or Mac. That includes S1-only and gen-1 players that never had AirPlay. The machine
running the hub (a Mac, or anything with Apple's Network framework) is the receiver: it
decodes the sender's audio and re-streams it to the room over plain HTTP.

```
iPhone ──RAOP (RTSP + RTP/UDP, AES)──▶ AirPlayStation (one per room)
                                          │  decrypt → ALAC decode → jitter buffer
                                          ▼  16-bit PCM
                                     AirPlayBridge ──▶ AudioServer (HTTP, endless WAV/MP3)
                                          │                       ▲
                                          └─SetAVTransportURI────▶ room coordinator ─┘ pulls the stream
```

## 1. Advertising: one target per room

`AirPlayReceiver.sync(rooms:)` keeps one `AirPlayStation` per room primary. Each station is
an `NWListener` advertised as `_raop._tcp`, named `<DEVICEID>@<Room name>`. The device id is
a stable FNV-1a hash of the room's primary uuid, so a room keeps its identity across
restarts. The TXT record offers PCM and ALAC (`cn=0,1`) and both plain and RSA/AES sessions
(`et=0,1`). iOS senders pick RSA/AES.

## 2. Handshake (RTSP)

| Request | What happens |
|---|---|
| `OPTIONS` + `Apple-Challenge` | Signed reply `Apple-Response`: challenge + receiver IP + hardware id, zero-padded to 32 bytes, RSA PKCS#1 v1.5 raw signature |
| `ANNOUNCE` (SDP) | Codec and `fmtp` (the ALAC magic cookie), `rsaaeskey` (RSA-OAEP wrapped AES key) and `aesiv` |
| `SETUP` | Server, control and timing UDP ports are allocated |
| `RECORD` / `FLUSH` | Start, or drop buffered audio on seek and skip |
| `SET_PARAMETER volume:` | Sender volume in dB (−30…0, −144 = mute) → `onVolume` |
| `TEARDOWN` | Sender left; the station goes back to `advertising` and the bridge stops the room |

The RSA key is the AirPort Express private key that Apple shipped in hardware. It was
extracted years ago and is used by every open AirPlay 1 receiver (shairport, shairplay,
AirConnect). It is interop plumbing, not a secret: it only lets the receiver present itself
as an AirPlay target. See `AirPlayCrypto.swift`.

## 3. Audio

- **Decrypt.** Each RTP payload is AES-128-CBC with the session key and IV. Only whole
  16-byte blocks are encrypted, and the tail is left in the clear.
- **Decode.** `ALACDecoder` uses CoreAudio's `AudioConverter`, set up from the SDP's
  `fmtp` (352 frames per packet, 44.1 kHz, stereo, 16 bit). PCM (`L16`) senders pass through.
- **Reorder.** `AirPlayJitterBuffer` orders packets by RTP sequence number. It prebuffers
  about 250 ms, fills a lost packet with silence, drops late duplicates and skips ahead if
  the backlog grows past about 2 s.

## 4. Re-streaming to the room

When a sender connects, `AirPlayBridge.begin` starts an `AudioServer` for that room and
tells the room's **group coordinator** to play it with `SetAVTransportURI` and `Play`,
titled `AirPlay · <room>`.

- **Modern players** get an endless WAV over plain `http://` (`/opensonos/mac.wav`).
- **Gen-1 players** (`Device.isLegacyStreamer`: `swGen == 1` or model S5) reject an endless
  WAV. They get MP3, encoded live with the vendored shine encoder (`CShine`), addressed as
  `x-rincon-mp3radio://…/opensonos/mac.mp3`, the scheme Sonos uses for internet radio.
  Silence tops up the stream when the sender pauses, so the player never runs dry.

The `AudioServer` address is picked with `LocalAddress.ipv4(near:)`, the local interface on
the speaker's subnet.

Sonos buffers the HTTP stream, so audio arrives a couple of seconds behind the sender. That
is fine for music and not suitable for video lip-sync.

## 5. Volume

`AirPlayVolume` makes the phone's buttons relative. The first volume report of a session
only records where the phone's slider sits against the room's current volume. After that,
the phone's remaining travel maps onto the room's remaining range. Connecting never jumps
the level, and a change made in the Sonos app in between is respected. Bursts of button
presses are coalesced per room.

## 6. Multi-room across S1 and S2

S1 and S2 rooms can never be grouped by Sonos. The bridge gets around that by feeding the
same PCM to more than one room:

```swift
try await hub.link(livingRoomPrimary, to: kitchenPrimary)  // Living Room also plays Kitchen's sender
hub.setDelay(livingRoomPrimary, ms: 300)                   // nudge rooms into sync by ear
await hub.unlink(livingRoomPrimary)
```

Each linked room has its own `AudioServer` and its own delay (0–2000 ms), and follows the
sender's volume buttons from its own level.

## Using the pieces directly

`AirPlayHub` is the convenient path. To fit it into an app with its own topology (as the
OpenSonos app does), wire `AirPlayReceiver` callbacks to an `AirPlayBridge` yourself:

```swift
receiver.onFormat = { primary, format in Task { await bridge.begin(primary, format: format,
    coordinatorIP: coordinator.ip, title: "AirPlay · \(name)", legacy: coordinator.isLegacyStreamer) } }
receiver.onAudio  = { primary, pcm in bridge.feed(primary, pcm) }       // RTP thread, no hops
receiver.onState  = { primary, state in if state != .connected { Task { await bridge.end(primary) } } }
receiver.onVolume = { primary, db in Task { await bridge.volume(primary, senderDB: db, ip: roomIP) } }
receiver.sync(rooms: [primary: name, …])
```

## Requirements and caveats

- AirPlay 1 (RAOP) only. AirPlay 2 features such as Apple-device multi-room and Siri
  "play in" are not implemented. Senders still list AirPlay 1 targets.
- The receiver needs Local Network access on macOS and iOS, and the Bonjour service types
  `_raop._tcp` in `NSBonjourServices` for an app.
- An iOS app can't stay reachable in the background, so run the receiver on a Mac or another
  always-on machine.
