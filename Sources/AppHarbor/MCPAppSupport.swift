import AppHarborCore
import AppHarborMCPBridge
import Foundation

enum MCPRequestStatus: String, Sendable {
    case preparing
    case awaitingConfirmation = "awaiting_confirmation"
    case running
    case succeeded
    case failed
    case outcomeUnknown = "outcome_unknown"
    case invalidated
    case guidance
    case blocked
    case declined
}

struct MCPRequestRecord: Sendable {
    let requestID: String
    let payloadFingerprint: String
    let operation: ManagedOperation
    let installationID: InstallationID
    var status: MCPRequestStatus
    var message: String
    var verification: VerificationResult?
    var createdAt: Date
    var updatedAt: Date
}

struct PendingMCPReview: Sendable {
    let requestID: String
    let payloadFingerprint: String
    let operation: ManagedOperation
    let installationID: InstallationID
    let displayName: String
    var planID: UUID?
    var expiresAt: Date
}

struct MCPPlanProvenance: Sendable {
    let requestID: String
    let expiresAt: Date
}

struct PlanSheetDismissal: Sendable {
    let presentationToken: UUID
    let mcpRequestID: String?
}

enum MCPAppResponse {
    static func make(_ fields: [String: Any], isError: Bool = false) -> MCPBridgeResponse {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return MCPBridgeResponse(json: #"{"error":"Could not encode AppHarbor response."}"#, isError: true)
        }
        return MCPBridgeResponse(json: json, isError: isError)
    }

    static func error(_ message: String) -> MCPBridgeResponse {
        make(["error": message], isError: true)
    }

    static func safeText(_ value: String) -> String {
        let home = NSHomeDirectory()
        let abbreviated = value.replacingOccurrences(of: home, with: "~")
        return PrivacyRedactor.redact(abbreviated)
    }
}
