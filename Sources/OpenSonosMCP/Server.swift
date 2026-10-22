import Foundation

/// One MCP tool: its schema and what it does.
struct Tool: Sendable {
    let name: String
    let description: String
    let schema: JSON
    /// True for tools that change a speaker; clients can ask before calling them.
    var writes = false
    let run: @Sendable (JSON) async throws -> JSON
}

/// A tool error the model should see as text (bad arguments, a missing room), not a protocol error.
struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// MCP over JSON-RPC 2.0: `initialize`, `ping`, `tools/list`, `tools/call`.
/// The transport is newline-delimited JSON on stdin/stdout (see main.swift).
struct Server: Sendable {
    static let protocolVersion = "2025-06-18"
    let name = "opensonos"
    let version = "0.1.0"
    let tools: [Tool]

    /// The reply to one message, or nil for a notification.
    func handle(_ message: JSON) async -> JSON? {
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return id.map { error($0, -32600, "Invalid request") }
        }
        // Notifications (no id) never get a reply.
        guard let id else { return nil }

        switch method {
        case "initialize":
            let asked = message["params"]?["protocolVersion"]?.string
            return result(id, [
                "protocolVersion": .string(asked ?? Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
                "instructions": """
                Controls Sonos speakers on the local network and turns each room into an AirPlay target. \
                Call list_systems first. Tools that change speakers say so; bonding tools need confirm=true \
                and always save a backup before they run.
                """,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": .array(tools.map(describe))])
        case "tools/call":
            guard let toolName = message["params"]?["name"]?.string,
                  let tool = tools.first(where: { $0.name == toolName }) else {
                return error(id, -32602, "Unknown tool")
            }
            let args = message["params"]?["arguments"] ?? [:]
            do {
                let value = try await tool.run(args)
                return result(id, ["content": [["type": "text", "text": .string(value.pretty())]]])
            } catch {
                return result(id, [
                    "content": [["type": "text", "text": .string(error.localizedDescription)]],
                    "isError": true,
                ])
            }
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    private func describe(_ tool: Tool) -> JSON {
        [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.schema,
            "annotations": ["readOnlyHint": .bool(!tool.writes), "openWorldHint": false],
        ]
    }

    private func result(_ id: JSON, _ value: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func error(_ id: JSON, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
