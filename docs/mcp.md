# MCP server

`opensonos-mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdio.
It has no dependencies and is built with the package:

```sh
swift build -c release
# binary: .build/release/opensonos-mcp
```

## Setup

Claude Code:

```sh
claude mcp add opensonos -- /path/to/opensonos/.build/release/opensonos-mcp
```

Claude Desktop, or any client with a JSON config:

```json
{
  "mcpServers": {
    "opensonos": {
      "command": "/path/to/opensonos/.build/release/opensonos-mcp",
      "env": { "OPENSONOS_MAX_VOLUME": "25" }
    }
  }
}
```

The machine running the server has to be on the same network as the speakers. On macOS,
allow Local Network access for the app that launches it when asked.

| Variable | Default | Meaning |
|---|---|---|
| `OPENSONOS_MAX_VOLUME` | `30` | `set_volume` refuses anything higher |
| `OPENSONOS_BACKUPS` | `~/Library/Application Support/OpenSonos/Backups` | Where topology backups go |

## Tools

Read-only:

| Tool | Does |
|---|---|
| `list_systems` | Every system (S1 and S2), with rooms, devices, models, IPs, roles and channels. Pass `refresh: true` to scan again |
| `now_playing` | State, source, title and artist of a room's group |
| `get_volume` | A room's volume |
| `plan_satellites` | The bonding steps for a soundbar layout, without running them |
| `list_backups` | Saved topology backups |
| `airplay_status` | AirPlay targets and which rooms each sender feeds |

Changes speakers (marked `readOnlyHint: false`):

| Tool | Does |
|---|---|
| `set_volume` | Sets a room's volume, capped by `OPENSONOS_MAX_VOLUME` |
| `transport` | `play`, `pause`, `next`, `previous` |
| `apply_satellites` | Runs a satellite layout. Needs `confirm: true`, saves a backup first, retries 800 and restores surround EQ |
| `restore_backup` | Plans (default) or applies (`confirm: true`) a return to a backup |
| `airplay_start` / `airplay_stop` | Advertise every room as an AirPlay target from this machine for as long as the server runs |
| `airplay_link` / `airplay_unlink` | Play one sender in another room too, across S1/S2 |
| `airplay_set_delay` | Per-room delay (0–2000 ms) to line rooms up |

Rooms are given by name (case-insensitive) or device uuid. Satellite layouts map speaker
to role:

```json
{
  "bar": "Living Room",
  "satellites": {
    "Sub": "sub",
    "Bedroom Left": "front_left",
    "Bedroom Right": "front_right"
  }
}
```

The list is the bar's complete layout: satellites it has now that are missing get unbonded.

## Protocol

JSON-RPC 2.0, one message per line. Supports `initialize`, `ping`, `tools/list` and
`tools/call`. Requests run concurrently, so `airplay_status` answers while a bonding run is
still going. Logs go to stderr. Try it by hand:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
              '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | .build/release/opensonos-mcp
```
