import Testing
@testable import OpenSonosMCP

// Protocol-level tests. None of these reach the network: the volume test is refused before
// any device is looked up.

private let server = Server(tools: makeTools(Sonos(environment: ["OPENSONOS_MAX_VOLUME": "10"])))

private func call(_ method: String, _ params: JSON = [:], id: JSON = 1) async -> JSON? {
    await server.handle(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
}

@Test func initializeEchoesProtocolVersion() async throws {
    let reply = try #require(await call("initialize", ["protocolVersion": "2025-03-26"]))
    #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
    #expect(reply["result"]?["serverInfo"]?["name"] == "opensonos")
    #expect(reply["result"]?["capabilities"]?["tools"] != nil)
}

@Test func notificationsGetNoReply() async {
    let reply = await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
    #expect(reply == nil)
}

@Test func listsToolsWithSchemas() async throws {
    let reply = try #require(await call("tools/list"))
    guard case let .array(tools)? = reply["result"]?["tools"] else { Issue.record("no tools"); return }
    let names = tools.compactMap { $0["name"]?.string }
    #expect(names.contains("list_systems"))
    #expect(names.contains("plan_satellites"))
    #expect(names.contains("airplay_start"))
    for tool in tools { #expect(tool["inputSchema"]?["type"] == "object") }
    let plan = tools.first { $0["name"] == "plan_satellites" }
    #expect(plan?["annotations"]?["readOnlyHint"] == true)
    let apply = tools.first { $0["name"] == "apply_satellites" }
    #expect(apply?["annotations"]?["readOnlyHint"] == false)
}

@Test func unknownMethodAndTool() async throws {
    let method = try #require(await call("resources/list"))
    #expect(method["error"]?["code"] == -32601)
    let tool = try #require(await call("tools/call", ["name": "nope"]))
    #expect(tool["error"]?["code"] == -32602)
}

@Test func volumeAboveLimitIsRefused() async throws {
    let reply = try #require(await call("tools/call", ["name": "set_volume", "arguments": ["room": "Kitchen", "volume": 50]]))
    #expect(reply["result"]?["isError"] == true)
    let text = reply["result"]?["content"].flatMap { if case let .array(a) = $0 { a.first?["text"]?.string } else { nil } }
    #expect(text?.contains("limit is 10") == true)
}

@Test func bondingNeedsConfirmation() async throws {
    let reply = try #require(await call("tools/call", ["name": "apply_satellites",
                                                       "arguments": ["bar": "Living Room", "satellites": [:]]]))
    #expect(reply["result"]?["isError"] == true)
}

@Test func jsonRoundTrip() throws {
    let value: JSON = ["a": [1, .number(2.5), "x", true, .null], "b": ["c": false]]
    #expect(try JSON.parse(value.line()) == value)
    #expect(JSON.number(3).line() == "3")
}
