import AppHarborCore
import CryptoKit
import Foundation

public enum MCPBridgeAction: String, Codable, Sendable {
    case listInstallations
    case listSources
    case getInstallation
    case refreshInventory
    case requestRemoval
    case requestUpdate
    case getRequestStatus
}

public struct MCPBridgeRequest: Codable, Sendable {
    public var action: MCPBridgeAction
    public var parameters: [String: String]

    public init(action: MCPBridgeAction, parameters: [String: String] = [:]) {
        self.action = action
        self.parameters = parameters
    }
}

public struct MCPBridgeResponse: Codable, Sendable {
    public var json: String
    public var isError: Bool

    public init(json: String, isError: Bool = false) {
        self.json = json
        self.isError = isError
    }
}

public enum MCPBridgeError: Error, LocalizedError, Sendable {
    case alreadyStarted
    case invalidSocketPath
    case unsafePath(String)
    case socketUnavailable(String)
    case timedOut
    case messageTooLarge
    case malformedMessage
    case peerIdentityMismatch
    case tooManyClients

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "The AppHarbor bridge is already running."
        case .invalidSocketPath: "The AppHarbor bridge socket path is too long or invalid."
        case .unsafePath(let path): "The AppHarbor bridge refused an unsafe socket path: \(path)"
        case .socketUnavailable(let detail): "The AppHarbor app is unavailable. Open AppHarbor and try again. (\(detail))"
        case .timedOut: "The AppHarbor app did not respond before the bridge timed out."
        case .messageTooLarge: "The AppHarbor bridge message exceeded its size limit."
        case .malformedMessage: "The AppHarbor bridge received an invalid message."
        case .peerIdentityMismatch: "The AppHarbor bridge peer belongs to a different user."
        case .tooManyClients: "The AppHarbor bridge is busy. Try again shortly."
        }
    }
}

public enum MCPBridgeRequestValidator {
    public static func validate(_ request: MCPBridgeRequest) throws {
        let p = request.parameters
        switch request.action {
        case .listInstallations:
            try keys(p, allowed: ["query", "offset", "limit"])
            if let query = p["query"], query.count > 256 { throw invalid("query must be 256 characters or fewer") }
            if let offset = p["offset"], let value = Int(offset), value >= 0, String(value) == offset {} else if p["offset"] != nil { throw invalid("offset must be a non-negative integer") }
            if let limit = p["limit"], let value = Int(limit), (1...100).contains(value), String(value) == limit {} else if p["limit"] != nil { throw invalid("limit must be an integer from 1 to 100") }
        case .listSources, .refreshInventory:
            try keys(p, allowed: [])
        case .getInstallation:
            try exact(p, ["installation_id"])
            try identifier(p["installation_id"]!)
        case .requestRemoval, .requestUpdate:
            try exact(p, ["installation_id", "request_id"])
            try identifier(p["installation_id"]!)
            try uuid(p["request_id"]!)
        case .getRequestStatus:
            try exact(p, ["request_id"])
            try uuid(p["request_id"]!)
        }
    }

    private static func exact(_ parameters: [String: String], _ required: Set<String>) throws {
        guard Set(parameters.keys) == required else { throw invalid("expected exactly: \(required.sorted().joined(separator: ", "))") }
    }

    private static func keys(_ parameters: [String: String], allowed: Set<String>) throws {
        guard Set(parameters.keys).isSubset(of: allowed) else { throw invalid("unknown parameter") }
    }

    private static func identifier(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw invalid("installation_id must be a lowercase SHA-256 identifier")
        }
    }

    private static func uuid(_ value: String) throws {
        guard let parsed = UUID(uuidString: value), parsed.uuidString.lowercased() == value.lowercased() else {
            throw invalid("request_id must be a UUID")
        }
    }

    private static func invalid(_ reason: String) -> NSError {
        NSError(domain: "AppHarborMCPBridge.Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

public enum MCPInventoryPresenter {
    public static func identifier(for identity: InstallationID) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(identity) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
