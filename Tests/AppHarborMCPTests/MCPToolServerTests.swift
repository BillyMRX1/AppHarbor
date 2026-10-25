import AppHarborMCPBridge
import Darwin
import Foundation
import MCP
import System
import XCTest
@testable import AppHarborMCP

final class MCPToolServerTests: XCTestCase {
    func testToolCatalogMetadataAndStrictArguments() throws {
        let tools = AppHarborMCPTools.all
        XCTAssertEqual(Set(tools.map(\.name)), [
            "appharbor_list_installations", "appharbor_list_sources", "appharbor_get_installation",
            "appharbor_refresh_inventory", "appharbor_request_removal", "appharbor_request_update",
            "appharbor_get_request_status"
        ])
        XCTAssertTrue(tools.first(where: { $0.name == "appharbor_list_sources" })?.annotations.readOnlyHint == true)
        XCTAssertTrue(tools.first(where: { $0.name == "appharbor_request_removal" })?.annotations.destructiveHint == true)
        XCTAssertTrue(tools.first(where: { $0.name == "appharbor_refresh_inventory" })?.annotations.openWorldHint == true)
        XCTAssertTrue(tools.first(where: { $0.name == "appharbor_get_request_status" })?.annotations.openWorldHint == false)

        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_list_sources", arguments: ["unexpected": .string("x")]))
        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_list_installations", arguments: ["limit": .double(2)]))
        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_list_installations", arguments: ["limit": .int(101)]))
        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_get_installation", arguments: [:]))
        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_get_installation", arguments: ["installation_id": .string("/tmp/target")]))
        XCTAssertThrowsError(try MCPToolServer.request(named: "appharbor_request_update", arguments: [
            "installation_id": .string(String(repeating: "a", count: 64)), "request_id": .string("not-a-uuid")
        ]))
    }

    func testRealStdioInitializeListAndAppAbsentToolCall() async throws {
        var inputPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer { close(inputPipe[0]); close(inputPipe[1]); close(outputPipe[0]); close(outputPipe[1]) }

        let server = await MCPToolServer.makeServer { _ in
            throw MCPBridgeError.socketUnavailable("Open AppHarbor to use the local inventory.")
        }
        let transport = MCP.StdioTransport(
            input: FileDescriptor(rawValue: inputPipe[0]),
            output: FileDescriptor(rawValue: outputPipe[1])
        )
        try await server.start(transport: transport)
        let input = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: false)

        try input.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"AppHarborTests","version":"1"}}}"#.utf8) + Data([10]))
        let initialized = try readJSONLine(from: output)
        XCTAssertEqual((initialized["id"] as? Int), 1)
        XCTAssertEqual(((initialized["result"] as? [String: Any])?["protocolVersion"] as? String), "2025-11-25")

        try input.write(contentsOf: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8) + Data([10]))
        try input.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8) + Data([10]))
        let listed = try readJSONLine(from: output)
        let listResult = listed["result"] as? [String: Any]
        let names = (listResult?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(names.count, 7)
        XCTAssertTrue(names.contains("appharbor_request_removal"))

        try input.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"appharbor_list_sources","arguments":{}}}"#.utf8) + Data([10]))
        let called = try readJSONLine(from: output)
        let callResult = called["result"] as? [String: Any]
        XCTAssertEqual(callResult?["isError"] as? Bool, true)
        let text = ((callResult?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("Open AppHarbor"))
        await server.stop()
    }

    private func readJSONLine(from handle: FileHandle) throws -> [String: Any] {
        var data = Data()
        while !data.contains(10) {
            guard let chunk = try handle.read(upToCount: 1), !chunk.isEmpty else {
                throw NSError(domain: "AppHarborMCPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "stdio stream ended before a response"])
            }
            data.append(chunk)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
    }
}
