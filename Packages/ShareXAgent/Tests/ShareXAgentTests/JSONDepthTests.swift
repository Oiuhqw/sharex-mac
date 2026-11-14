import Foundation
import Testing
@testable import ShareXAgent

func nestedArrays(_ count: Int) -> String {
    String(repeating: "[", count: count) + String(repeating: "]", count: count)
}

private func ping(params: String) -> String {
    #"{"jsonrpc":"2.0","id":7,"method":"ping","params":\#(params)}"#
}

/// Object keys that JSONDecoder in swift-foundation 6.0 traps on.
let malformedKeys = [Data(#"\q"#.utf8), Data("\u{1}".utf8), Data(#"\ud800"#.utf8), Data(#"\u12zz"#.utf8), Data([0xFF])]

private func expectRefusedThenServing(_ server: MCPServer, _ line: Data, code: Double = -32600) throws {
    let value = try #require(server.handle(line))
    guard case .object(let refused) = value, case .object(let error) = refused["error"] else { Issue.record("Expected an error reply"); return }
    #expect(refused["id"] == .null)
    #expect(error["code"] == .number(code))
    #expect(try rpc(server, #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)["result"] == .object([:]))
}

@Test(arguments: [33, 400])
func mcpRefusesLineNestedBeyondLimitAndKeepsServing(depth: Int) throws {
    try expectRefusedThenServing(initializedServer(), Data(ping(params: #"{"a":\#(nestedArrays(depth - 2))}"#).utf8))
}

@Test func mcpAcceptsLineNestedToLimit() throws {
    let response = try rpc(initializedServer(), ping(params: #"{"a":\#(nestedArrays(30))}"#))
    #expect(response["id"] == .number(7))
    #expect(response["result"] == .object([:]))
}

@Test func mcpDepthIgnoresBracketsInsideStrings() throws {
    let brackets = String(repeating: "[{", count: 200)
    let response = try rpc(initializedServer(), ping(params: #"{"plain":"\#(brackets)","afterEscapedQuote":"\"\#(brackets)"}"#))
    #expect(response["result"] == .object([:]))
}

@Test func mcpDepthCountsBracketsAfterStringEndingInEscapedBackslash() throws {
    try expectRefusedThenServing(initializedServer(), Data(ping(params: #"{"a":"\\","b":\#(nestedArrays(31))}"#).utf8))
}

@Test func mcpRefusesNestedLineInUTF16() throws {
    let line = try #require(ping(params: #"{"a\"":\#(nestedArrays(400))}"#).data(using: .utf16LittleEndian))
    try expectRefusedThenServing(initializedServer(), line)
}

@Test func mcpAnswersMalformedObjectKeyWithParseErrorAndKeepsServing() throws {
    let server = try initializedServer()
    try expectRefusedThenServing(server, Data(#"{"\q":1}"#.utf8), code: -32700)
    for key in malformedKeys {
        let line = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{""#.utf8) + key + Data(#"":1}}"#.utf8)
        try expectRefusedThenServing(server, line, code: -32700)
    }
}

@Test(arguments: ["5", #""text""#, "true", "null"])
func mcpAnswersScalarWithInvalidRequest(line: String) throws {
    let response = try rpc(MCPServer { .success($0.id, .null) }, line)
    guard case .object(let error) = response["error"] else { Issue.record("Expected an error reply"); return }
    #expect(error["code"] == .number(-32600))
}
