import Foundation

public struct DetectionResult: Sendable {
    public var presence: ManagerPresence; public var instances: [ManagerInstance]; public var explanation: String?
    public init(presence: ManagerPresence, instances: [ManagerInstance] = [], explanation: String? = nil) { self.presence = presence; self.instances = instances; self.explanation = explanation }
}
public struct AdapterInventoryResult: Sendable {
    public var installations: [Installation]; public var coverage: CoverageSnapshot
    public init(installations: [Installation], coverage: CoverageSnapshot) { self.installations = installations; self.coverage = coverage }
}
public protocol PackageManagerAdapter: Sendable {
    var kind: ManagerKind { get }
    func detect(using runner: any ProcessRunning) async -> DetectionResult
    func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult
    func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision
    func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult
    func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult
    func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult
}

public extension PackageManagerAdapter {
    func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        UpdateCheckResult(installationID: installation.identity, status: .unsupported, currentVersion: installation.version, explanation: "This adapter has no validated update check for this installation.")
    }
}
