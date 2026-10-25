import MCP

enum AppHarborMCPTools {
    static let all: [MCP.Tool] = [
        tool("appharbor_list_installations", "List AppHarbor's cached installation inventory.", .init(readOnlyHint: true, openWorldHint: false), properties: [
            "query": .init(type: "string", description: "Optional case-insensitive name, source, or location search (up to 256 characters)."),
            "offset": .init(type: "integer", description: "Zero-based result offset; defaults to 0."),
            "limit": .init(type: "integer", description: "Page size from 1 to 100; defaults to 25.")
        ]),
        tool("appharbor_list_sources", "List package sources and scan scopes detected by AppHarbor.", .init(readOnlyHint: true, openWorldHint: false)),
        tool("appharbor_get_installation", "Get the cached details for one installation by its 64-character SHA-256 installation_id.", .init(readOnlyHint: true, openWorldHint: false), properties: [
            "installation_id": .init(type: "string", description: "64-character lowercase SHA-256 identifier returned by appharbor_list_installations.")
        ], required: ["installation_id"]),
        tool("appharbor_refresh_inventory", "Ask the running AppHarbor app to refresh supported package sources and its local inventory.", .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)),
        tool("appharbor_request_removal", "Create a removal review request in AppHarbor. The app presents the target and requires the user to review and confirm; this tool does not execute removal.", .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true), properties: [
            "installation_id": .init(type: "string", description: "64-character lowercase SHA-256 identifier returned by appharbor_list_installations."),
            "request_id": .init(type: "string", description: "Caller-generated UUID used as an idempotency key for this review request.")
        ], required: ["installation_id", "request_id"]),
        tool("appharbor_request_update", "Create an update review request in AppHarbor. The app presents the target and requires the user to review and confirm; this tool does not execute an update.", .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true), properties: [
            "installation_id": .init(type: "string", description: "64-character lowercase SHA-256 identifier returned by appharbor_list_installations."),
            "request_id": .init(type: "string", description: "Caller-generated UUID used as an idempotency key for this review request.")
        ], required: ["installation_id", "request_id"]),
        tool("appharbor_get_request_status", "Get the current state of an AppHarbor review request by its UUID.", .init(readOnlyHint: true, openWorldHint: false), properties: [
            "request_id": .init(type: "string", description: "UUID returned when a review request was created.")
        ], required: ["request_id"])
    ]

    private struct Property {
        let type: String
        let description: String
        init(type: String, description: String) { self.type = type; self.description = description }
        var value: MCP.Value { .object(["type": .string(type), "description": .string(description)]) }
    }

    private static func tool(_ name: String, _ description: String, _ annotations: MCP.Tool.Annotations,
                             properties: [String: Property] = [:], required: [String] = []) -> MCP.Tool {
        let schema = MCP.Value.object([
            "type": .string("object"),
            "properties": .object(properties.mapValues(\.value)),
            "required": .array(required.map(MCP.Value.string)),
            "additionalProperties": .bool(false)
        ])
        return MCP.Tool(name: name, description: description, inputSchema: schema, annotations: annotations)
    }
}
