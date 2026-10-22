import Foundation

// opensonos-mcp: an MCP server on stdio (newline-delimited JSON-RPC). Logs go to stderr,
// since stdout carries only protocol messages.

/// Serializes writes to stdout so concurrent replies never interleave.
actor Output {
    func send(_ message: JSON) {
        FileHandle.standardOutput.write(Data((message.line() + "\n").utf8))
    }
}

let server = Server(tools: makeTools(Sonos()))
let output = Output()

var running: [Task<Void, Never>] = []
for try await line in FileHandle.standardInput.bytes.lines {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let message = try? JSON.parse(line) else {
        await output.send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    // Each request runs on its own, so a long bonding run never blocks ping or status.
    running.append(Task {
        if let reply = await server.handle(message) { await output.send(reply) }
    })
}
// stdin closed: finish what is in flight before exiting.
for task in running { await task.value }
