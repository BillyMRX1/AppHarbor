import Foundation

public enum ManagerKind: String, Codable, CaseIterable, Sendable { case appBundle, homebrew, npm, pipx, cargo, other }
public enum ManagerPresence: String, Codable, Sendable { case present, absent, unavailable, unsupportedVersion }
public enum InstallationKind: String, Codable, Sendable { case appBundle, formula, cask, npmPackage, pipxEnvironment, cargoPackage, other }
public enum OwnershipConfidence: String, Codable, Sendable { case verified, strong, ambiguous, unknown }
public enum CoverageState: String, Codable, Sendable { case complete, partial, failed }
public enum ManagedOperation: String, Codable, Sendable { case remove, update }
public enum UpdateStatus: String, Codable, Sendable { case updateAvailable, upToDate, unknown, failed, unsupported }
public struct UpdateCheckResult: Codable, Sendable, Identifiable {
    public var id: InstallationID { installationID }
    public var installationID: InstallationID
    public var status: UpdateStatus
    public var currentVersion: String?
    public var availableVersion: String?
    public var checkedAt: Date
    public var explanation: String?
    public init(installationID: InstallationID, status: UpdateStatus, currentVersion: String? = nil, availableVersion: String? = nil, checkedAt: Date = .now, explanation: String? = nil) {
        self.installationID = installationID; self.status = status; self.currentVersion = currentVersion
        self.availableVersion = availableVersion; self.checkedAt = checkedAt; self.explanation = explanation
    }
}
public enum VerificationResult: String, Codable, Sendable { case verifiedRemoved, verifiedUpdated, stillPresent, versionUnchanged, incomplete, notAttempted }
public enum TaskState: String, Codable, Sendable { case awaitingConfirmation, running, verifying, succeeded, failed, outcomeUnknown, invalidated }
public enum StorageStatus: Codable, Hashable, Sendable { case available, readFailure(String), writeFailure(String) }

public struct ManagerScope: Codable, Hashable, Sendable, Identifiable {
    public var id: String; public var displayName: String; public var canonicalRoot: String?; public var isExplicitlySelected: Bool
    public init(id: String, displayName: String, canonicalRoot: String? = nil, isExplicitlySelected: Bool = false) { self.id = id; self.displayName = displayName; self.canonicalRoot = canonicalRoot; self.isExplicitlySelected = isExplicitlySelected }
}
public struct ManagerEvidence: Codable, Hashable, Sendable {
    public var label: String; public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}
public struct ManagerInstance: Codable, Hashable, Sendable, Identifiable {
    public var id: String; public var kind: ManagerKind; public var executablePath: String; public var executableFingerprint: String
    public var version: String?; public var architecture: String?; public var scope: ManagerScope; public var presence: ManagerPresence
    public var evidence: [ManagerEvidence]; public var removalSupported: Bool; public var updateSupported: Bool
    public init(id: String, kind: ManagerKind, executablePath: String, executableFingerprint: String, version: String? = nil, architecture: String? = nil, scope: ManagerScope, presence: ManagerPresence = .present, evidence: [ManagerEvidence] = [], removalSupported: Bool = false, updateSupported: Bool = false) {
        self.id = id; self.kind = kind; self.executablePath = executablePath; self.executableFingerprint = executableFingerprint
        self.version = version; self.architecture = architecture; self.scope = scope; self.presence = presence; self.evidence = evidence
        self.removalSupported = removalSupported; self.updateSupported = updateSupported
    }
}
public struct InstallationID: Codable, Hashable, Sendable, CustomStringConvertible {
    public var managerID: String; public var scopeID: String; public var nativeID: String; public var canonicalLocation: String
    public init(managerID: String, scopeID: String, nativeID: String, canonicalLocation: String) { self.managerID = managerID; self.scopeID = scopeID; self.nativeID = nativeID; self.canonicalLocation = canonicalLocation }
    public var description: String { "\(managerID)|\(scopeID)|\(nativeID)|\(canonicalLocation)" }
}
public struct Installation: Codable, Hashable, Sendable, Identifiable {
    public var id: InstallationID { identity }; public var identity: InstallationID; public var kind: InstallationKind
    public var displayName: String; public var version: String?; public var canonicalLocation: String; public var bundleIdentifier: String?
    public var ownership: OwnershipConfidence; public var evidence: [ManagerEvidence]; public var isProtected: Bool; public var protectionReason: String?
    public var observedAt: Date; public var removalSupported: Bool; public var updateSupported: Bool; public var isStale: Bool
    public init(identity: InstallationID, kind: InstallationKind, displayName: String, version: String? = nil, canonicalLocation: String, bundleIdentifier: String? = nil, ownership: OwnershipConfidence, evidence: [ManagerEvidence] = [], isProtected: Bool = false, protectionReason: String? = nil, observedAt: Date = .now, removalSupported: Bool = false, updateSupported: Bool = false, isStale: Bool = false) {
        self.identity = identity; self.kind = kind; self.displayName = displayName; self.version = version; self.canonicalLocation = canonicalLocation
        self.bundleIdentifier = bundleIdentifier; self.ownership = ownership; self.evidence = evidence; self.isProtected = isProtected
        self.protectionReason = protectionReason; self.observedAt = observedAt; self.removalSupported = removalSupported; self.updateSupported = updateSupported; self.isStale = isStale
    }
}
public struct CoverageSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String; public var sourceName: String; public var scopeID: String; public var state: CoverageState
    public var startedAt: Date; public var completedAt: Date?; public var itemCount: Int; public var omittedScopes: [String]; public var warning: String?
    public init(id: String, sourceName: String, scopeID: String, state: CoverageState, startedAt: Date = .now, completedAt: Date? = nil, itemCount: Int = 0, omittedScopes: [String] = [], warning: String? = nil) {
        self.id = id; self.sourceName = sourceName; self.scopeID = scopeID; self.state = state; self.startedAt = startedAt
        self.completedAt = completedAt; self.itemCount = itemCount; self.omittedScopes = omittedScopes; self.warning = warning
    }
}
public struct InventorySnapshot: Codable, Sendable {
    public var installations: [Installation]; public var managers: [ManagerInstance]; public var coverage: [CoverageSnapshot]; public var updateChecks: [UpdateCheckResult]; public var refreshedAt: Date
    public init(installations: [Installation], managers: [ManagerInstance], coverage: [CoverageSnapshot], updateChecks: [UpdateCheckResult] = [], refreshedAt: Date = .now) { self.installations = installations; self.managers = managers; self.coverage = coverage; self.updateChecks = updateChecks; self.refreshedAt = refreshedAt }
}
public struct ProcessCommand: Codable, Hashable, Sendable {
    public var executablePath: String; public var arguments: [String]; public var environment: [String: String]; public var workingDirectory: String?
    public var timeout: TimeInterval; public var maximumOutputBytes: Int
    public init(executablePath: String, arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil, timeout: TimeInterval = 120, maximumOutputBytes: Int = 1_048_576) {
        self.executablePath = executablePath; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
        self.timeout = timeout; self.maximumOutputBytes = maximumOutputBytes
    }
}
public enum ActionExecution: Codable, Sendable {
    case process(ProcessCommand)
    case appBundleTrash(AppBundleTrashTarget)
}
public struct ActionPlan: Codable, Sendable, Identifiable {
    public var id: UUID; public var installationID: InstallationID; public var operation: ManagedOperation; public var managerInstanceID: String
    public var execution: ActionExecution; public var executableFingerprint: String; public var targetFingerprint: String; public var previewCommand: String
    public var knownEffects: [String]; public var unknownEffects: [String]; public var expectedResult: String; public var privilegeRequired: Bool
    public var approvedUpdateVersion: String?; public var approvedSourcePolicy: String?
    public var createdAt: Date; public var expiresAt: Date
    public init(id: UUID = UUID(), installationID: InstallationID, operation: ManagedOperation, managerInstanceID: String, command: ProcessCommand, executableFingerprint: String, targetFingerprint: String, previewCommand: String, knownEffects: [String] = [], unknownEffects: [String] = [], expectedResult: String, privilegeRequired: Bool = false, approvedUpdateVersion: String? = nil, approvedSourcePolicy: String? = nil, createdAt: Date = .now, expiresAt: Date = .now.addingTimeInterval(300)) {
        self.id = id; self.installationID = installationID; self.operation = operation; self.managerInstanceID = managerInstanceID; self.execution = .process(command)
        self.executableFingerprint = executableFingerprint; self.targetFingerprint = targetFingerprint; self.previewCommand = previewCommand
        self.knownEffects = knownEffects; self.unknownEffects = unknownEffects; self.expectedResult = expectedResult; self.privilegeRequired = privilegeRequired
        self.approvedUpdateVersion = approvedUpdateVersion; self.approvedSourcePolicy = approvedSourcePolicy
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }
    public init(id: UUID = UUID(), installationID: InstallationID, operation: ManagedOperation, managerInstanceID: String, trashTarget: AppBundleTrashTarget, executableFingerprint: String = "native-app-trash", targetFingerprint: String? = nil, previewCommand: String = "Move the selected app to Trash", knownEffects: [String] = [], unknownEffects: [String] = [], expectedResult: String = "The app is in Trash and absent from its original location.", privilegeRequired: Bool = false, approvedUpdateVersion: String? = nil, approvedSourcePolicy: String? = nil, createdAt: Date = .now, expiresAt: Date = .now.addingTimeInterval(300)) {
        self.id = id; self.installationID = installationID; self.operation = operation; self.managerInstanceID = managerInstanceID; self.execution = .appBundleTrash(trashTarget)
        self.executableFingerprint = executableFingerprint; self.targetFingerprint = targetFingerprint ?? trashTarget.metadataFingerprint; self.previewCommand = previewCommand
        self.knownEffects = knownEffects; self.unknownEffects = unknownEffects; self.expectedResult = expectedResult; self.privilegeRequired = privilegeRequired
        self.approvedUpdateVersion = approvedUpdateVersion; self.approvedSourcePolicy = approvedSourcePolicy
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }
    /// Compatibility accessor for existing process-backed adapters. Native plans have no command.
    public var command: ProcessCommand? { if case let .process(command) = execution { return command }; return nil }
}
public struct RemovalGuidance: Codable, Sendable {
    public var title: String; public var steps: [String]; public var displayCommand: String?; public var sourceURL: URL?; public var isVerified: Bool
    public init(title: String, steps: [String], displayCommand: String? = nil, sourceURL: URL? = nil, isVerified: Bool) { self.title = title; self.steps = steps; self.displayCommand = displayCommand; self.sourceURL = sourceURL; self.isVerified = isVerified }
}
public enum PlanDecision: Sendable { case ready(ActionPlan), guidance(RemovalGuidance, reason: String), blocked(reason: String) }
public enum PreflightResult: Sendable { case valid(currentTargetFingerprint: String, currentExecutableFingerprint: String), invalidated(reason: String) }
public struct TaskRecord: Codable, Sendable, Identifiable {
    public var id: UUID; public var planID: UUID; public var installationID: InstallationID; public var operation: ManagedOperation; public var state: TaskState
    public var startedAt: Date; public var completedAt: Date?; public var exitCode: Int32?; public var redactedSummary: String; public var verification: VerificationResult
    public init(id: UUID = UUID(), planID: UUID, installationID: InstallationID, operation: ManagedOperation, state: TaskState, startedAt: Date = .now, completedAt: Date? = nil, exitCode: Int32? = nil, redactedSummary: String, verification: VerificationResult = .notAttempted) {
        self.id = id; self.planID = planID; self.installationID = installationID; self.operation = operation; self.state = state
        self.startedAt = startedAt; self.completedAt = completedAt; self.exitCode = exitCode; self.redactedSummary = redactedSummary; self.verification = verification
    }
}
public enum EngineEvent: Sendable { case inventoryChanged(InventorySnapshot), operationChanged(TaskRecord) }
