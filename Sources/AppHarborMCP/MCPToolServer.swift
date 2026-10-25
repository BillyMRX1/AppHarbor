import AppHarborMCPBridge
import Foundation
import MCP

enum MCPToolServer {
    typealias BridgeSender = @Sendable (MCPBridgeRequest) async throws -> MCPBridgeResponse

    static func makeServer(bridgeSend: @escaping BridgeSender = { request in
        try await MCPBridgeClient.send(request)
    }) async -> MCP.Server {
        let server = MCP.Server(name: "appharbor", version: "0.3.0", capabilities: .init(tools: .init()), configuration: .strict)
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            MCP.ListTools.Result(tools: AppHarborMCPTools.all)
        }
        await server.withMethodHandler(MCP.CallTool.self) { parameters in
            await callTool(parameters, bridgeSend: bridgeSend)
        }
        return server
    }

    static func callTool(_ call: MCP.CallTool.Parameters, bridgeSend: @escaping BridgeSender) async -> MCP.CallTool.Result {
        do {
            let request = try request(named: call.name, arguments: call.arguments ?? [:])
            let response = try await bridgeSend(request)
            return MCP.CallTool.Result(content: [.text(text: response.json, annotations: nil, _meta: nil)], isError: response.isError)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let json = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"AppHarbor MCP request failed\"}"
            return MCP.CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: true)
        }
    }

    static func request(named name: String, arguments: [String: MCP.Value]) throws -> MCPBridgeRequest {
        switch name {
        case "appharbor_list_installations":
            try rejectUnknown(arguments, allowed: ["query", "offset", "limit"])
            var parameters: [String: String] = [:]
            if let value = arguments["query"] { parameters["query"] = try string(value, named: "query") }
            if let value = arguments["offset"] { parameters["offset"] = try integer(value, named: "offset") }
            if let value = arguments["limit"] { parameters["limit"] = try integer(value, named: "limit") }
            return try validated(.init(action: .listInstallations, parameters: parameters))
        case "appharbor_list_sources":
            try rejectUnknown(arguments, allowed: [])
            return try validated(.init(action: .listSources))
        case "appharbor_get_installation":
            try requireKeys(arguments, ["installation_id"])
            return try validated(.init(action: .getInstallation, parameters: ["installation_id": try string(arguments["installation_id"]!, named: "installation_id")]))
        case "appharbor_refresh_inventory":
            try rejectUnknown(arguments, allowed: [])
            return try validated(.init(action: .refreshInventory))
        case "appharbor_request_removal", "appharbor_request_update":
            try requireKeys(arguments, ["installation_id", "request_id"])
            let parameters = [
                "installation_id": try string(arguments["installation_id"]!, named: "installation_id"),
                "request_id": try string(arguments["request_id"]!, named: "request_id")
            ]
            let action: MCPBridgeAction = name == "appharbor_request_removal" ? .requestRemoval : .requestUpdate
            return try validated(.init(action: action, parameters: parameters))
        case "appharbor_get_request_status":
            try requireKeys(arguments, ["request_id"])
            return try validated(.init(action: .getRequestStatus, parameters: ["request_id": try string(arguments["request_id"]!, named: "request_id")]))
        default:
            throw ToolInputError("Unknown AppHarbor tool: \(name)")
        }
    }

    private static func validated(_ request: MCPBridgeRequest) throws -> MCPBridgeRequest {
        try MCPBridgeRequestValidator.validate(request)
        return request
    }

    private static func requireKeys(_ arguments: [String: MCP.Value], _ expected: Set<String>) throws {
        guard Set(arguments.keys) == expected else {
            throw ToolInputError("Expected exactly these arguments: \(expected.sorted().joined(separator: ", ")).")
        }
    }

    private static func rejectUnknown(_ arguments: [String: MCP.Value], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else { throw ToolInputError("Unknown tool argument.") }
    }

    private static func string(_ value: MCP.Value, named name: String) throws -> String {
        guard let string = value.stringValue else { throw ToolInputError("\(name) must be a string.") }
        return string
    }

    private static func integer(_ value: MCP.Value, named name: String) throws -> String {
        guard let integer = value.intValue else { throw ToolInputError("\(name) must be an integer.") }
        return String(integer)
    }

    private struct ToolInputError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
