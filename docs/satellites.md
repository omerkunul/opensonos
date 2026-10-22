# Adding satellites to a soundbar

Sonos lets a soundbar take a Sub and two rear surrounds. Its app only offers certain models
for each role. The firmware accepts more. With `AddHTSatellite` any Sonos speaker can be a
sub, a rear, **or a front left/right** (`LF`/`RF`), which the app never offers. For example,
two Play:1s can become fronts next to an old Playbar, so the bar plays the center channel.

## Channel tokens

`ZoneGroupState` describes each bond with a channel map:

```
Stereo pair   (ChannelMapSet):    RINCON_A:LF,LF;RINCON_B:RF,RF
Home theater  (HTSatChanMapSet):  RINCON_BAR:LF,RF;RINCON_SUB:SW;RINCON_L:LR;RINCON_R:RR
```

| Token | Role (`Role`) |
|---|---|
| `LF,RF` (or `CC`) | soundbar |
| `SW` | sub |
| `LR` / `RR` | rear left / rear right (`surroundLeft` / `surroundRight`) |
| `LF` / `RF` | front left / front right (`frontLeft` / `frontRight`) |
| `LF,LF` / `RF,RF` | stereo pair left / right |

Each satellite's own map lists only the bar and itself. The full layout is the union of
every member's map, and `parseZoneGroupState` builds that union into `Room.htMap`.

Firmware may expand a token, for example `LF` to `LF,LTF` with a height channel.
`ChannelMap.sameChannel` treats those as the same channel. Only the first token is ever sent.

## The planner

```swift
let steps = Planner.layout(hh, bar: barUUID, assignments: [
    subUUID:   .sub,
    leftUUID:  .frontLeft,
    rightUUID: .frontRight,
])
```

`assignments` is the bar's **complete** satellite list. A satellite the bar has now but that
is missing from `assignments` gets unbonded. A speaker that sits in a stereo pair, or on
another bar, is released from there first. `Planner.plan(hh, to: Target)` does the same for a
whole household, and `Planner.restore(hh, to: backup.household)` brings back a backup.

Steps come out in a safe order:

1. **Unbond** whatever doesn't match (`separatePair`, `removeSatellite`).
2. **Create stereo pairs** (`createPair`).
3. **Add satellites** in the order sub, rears, fronts (`addSatellite`).

Nothing is sent to a speaker that is already where it should be. Show the steps first with
`step.describe(hh)`.

## The bonder

```swift
try BackupStore().save(hh, label: "before fronts")
let final = try await Bonder(client: client).run(steps, on: hh) { event in print(event) }
```

| Step | SOAP call (DeviceProperties) | Sent to |
|---|---|---|
| `createPair` | `CreateStereoPair(ChannelMapSet)` | left speaker |
| `separatePair` | `SeparateStereoPair(ChannelMapSet)` | pair primary |
| `removeSatellite` | `RemoveHTSatellite(SatRoomUUID)` | the bar |
| `addSatellite` | `AddHTSatellite(HTSatChanMapSet = BAR:LF,RF;SAT:<token>)` | the bar |

What the bonder handles for you:

- **Error 800 after unbonding.** A speaker that was just unbonded or regrouped answers
  `AddHTSatellite` with UPnP 800 for about 3 to 15 seconds. The bonder retries every
  3 seconds for up to 30 seconds. A 402 is a real rejection and stops the run.
- **Waiting for the topology.** After each write it polls `ZoneGroupState` (1.5 s interval,
  60 s timeout) until the expected bond shows up.
- **Surround EQ reset.** Rebonding resets the bar's surround settings
  (`EQType.surroundKeys`: surround on/off, levels, mode, sub gain, height). The bonder reads them before the run and writes back any that changed.
- **Playbar `CC` token.** The Playbar accepts `CC` for itself but reverts it after about a
  minute. The bonder keeps the bar on `LF,RF`, which sticks.

## Limits

- All members must be in the **same household**. An S1 speaker can't join an S2 bar.
- A satellite stops being its own room while bonded, so it disappears from room lists and
  the AirPlay menu.
- Fronts change how the bar's channels are split. Check the result by ear, and adjust
  `SurroundLevel` / `MusicSurroundLevel` (`client.setEQ`) if needed.
- Keep a backup. `Planner.restore` plus `Bonder` brings any saved layout back.
