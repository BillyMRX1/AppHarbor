import Foundation

public protocol InstallationStoring: Sendable {
    func loadSnapshot() async -> InventorySnapshot
    func saveSnapshot(_ snapshot: InventorySnapshot) async
    func appendTask(_ record: TaskRecord) async
    func loadTasks() async -> [TaskRecord]
    func storageStatus() async -> StorageStatus
}
public extension InstallationStoring {
    func storageStatus() async -> StorageStatus { .available }
}

/// Small default store. Applications can replace it with a durable implementation.
public actor InMemoryInstallationStore: InstallationStoring {
    private var snapshot = InventorySnapshot(installations: [], managers: [], coverage: [])
    private var tasks: [TaskRecord] = []
    public init() {}
    public func loadSnapshot() -> InventorySnapshot { snapshot }
    public func saveSnapshot(_ snapshot: InventorySnapshot) { self.snapshot = snapshot }
    public func appendTask(_ record: TaskRecord) {
        tasks.removeAll { $0.id == record.id }; tasks.append(record)
        tasks = Array(tasks.suffix(200))
    }
    public func loadTasks() -> [TaskRecord] { tasks }
}

public actor AppHarborCoreEngine {
    private let adapters: [any PackageManagerAdapter]
    private let runner: any ProcessRunning
    private let store: any InstallationStoring
    private var cachedSnapshot: InventorySnapshot?
    private var plans: [UUID: ActionPlan] = [:]
    private var activePlanIDs = Set<UUID>()
    private var lockedRoots = Set<String>()
    private var refreshInProgress = false
    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    public init(adapters: [any PackageManagerAdapter], runner: any ProcessRunning = FoundationProcessRunner(), store: (any InstallationStoring)? = nil) {
        self.adapters = adapters; self.runner = runner; self.store = store ?? LocalJSONInstallationStore.applicationDefault()
    }

    public func events() -> AsyncStream<EngineEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
    }

    public func currentSnapshot() async -> InventorySnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        var loaded = await store.loadSnapshot()
        for index in loaded.installations.indices { loaded.installations[index].isStale = true }
        cachedSnapshot = loaded; return loaded
    }

    public func storageStatus() async -> StorageStatus { await store.storageStatus() }

    /// Re-scans registered sources, publishes each completed scope, and keeps unverified cached rows stale.
    public func refresh() async -> InventorySnapshot {
        if refreshInProgress { return await currentSnapshot() }
        refreshInProgress = true
        defer { refreshInProgress = false }
        let original = await currentSnapshot()
        var managersByID = Dictionary(uniqueKeysWithValues: original.managers.map { ($0.id, $0) })
        var rowsByID = Dictionary(uniqueKeysWithValues: original.installations.map { ($0.identity, $0) })
        var coverageByID = Dictionary(uniqueKeysWithValues: original.coverage.map { ($0.id, $0) })
        for key in Array(rowsByID.keys) { rowsByID[key]?.isStale = true }
        var progress = makeSnapshot(managers: managersByID, rows: rowsByID, coverage: coverageByID, checks: original.updateChecks)
        cachedSnapshot = progress; await store.saveSnapshot(progress); publish(.inventoryChanged(progress))

        for adapter in adapters {
            if Task.isCancelled { break }
            let detection = await adapter.detect(using: runner)
            if Task.isCancelled { break }
            let discoveredIDs = Set(detection.instances.map(\.id))
            for (oldID, oldManager) in Array(managersByID) where oldManager.kind == adapter.kind && !discoveredIDs.contains(oldID) {
                var updated = oldManager
                updated.presence = detection.instances.isEmpty ? detection.presence : .unavailable
                managersByID[oldID] = updated
                for key in Array(rowsByID.keys) where key.managerID == oldID { rowsByID[key]?.isStale = true }
            }
            for instance in detection.instances { managersByID[instance.id] = instance }
            if !detection.instances.isEmpty { coverageByID.removeValue(forKey: "\(adapter.kind.rawValue):detection") }
            if detection.instances.isEmpty {
                let coverage = CoverageSnapshot(id: "\(adapter.kind.rawValue):detection", sourceName: adapter.kind.rawValue, scopeID: "detection", state: detection.presence == .absent ? .complete : .failed, warning: detection.explanation)
                coverageByID[coverage.id] = coverage
                progress = makeSnapshot(managers: managersByID, rows: rowsByID, coverage: coverageByID, checks: (cachedSnapshot ?? original).updateChecks)
                cachedSnapshot = progress; await store.saveSnapshot(progress); publish(.inventoryChanged(progress))
                continue
            }
            for instance in detection.instances {
                if Task.isCancelled { break }
                let result = await adapter.inventory(instance: instance, using: runner)
                if Task.isCancelled { break }
                coverageByID[result.coverage.id] = result.coverage
                if result.coverage.state == .complete {
                    rowsByID = rowsByID.filter { !($0.key.managerID == instance.id && $0.key.scopeID == instance.scope.id) }
                } else {
                    for key in Array(rowsByID.keys) where key.managerID == instance.id && key.scopeID == instance.scope.id { rowsByID[key]?.isStale = true }
                }
                for var installation in result.installations { installation.isStale = false; rowsByID[installation.identity] = installation }
                progress = makeSnapshot(managers: managersByID, rows: rowsByID, coverage: coverageByID, checks: (cachedSnapshot ?? original).updateChecks)
                cachedSnapshot = progress; await store.saveSnapshot(progress); publish(.inventoryChanged(progress))
            }
        }
        let newestChecks = (cachedSnapshot ?? original).updateChecks
        let checks = newestChecks.filter { check in
            guard let item = rowsByID[check.installationID], let version = item.version else { return rowsByID[check.installationID] != nil && check.currentVersion == nil }
            return check.currentVersion == version
        }
        progress = makeSnapshot(managers: managersByID, rows: rowsByID, coverage: coverageByID, checks: checks)
        cachedSnapshot = progress; await store.saveSnapshot(progress); publish(.inventoryChanged(progress))
        return progress
    }

    private func makeSnapshot(managers: [String: ManagerInstance], rows: [InstallationID: Installation], coverage: [String: CoverageSnapshot], checks: [UpdateCheckResult]) -> InventorySnapshot {
        let values = Array(rows.values)
        let linkedBundleIDs = Set(values.filter { $0.kind == .cask }.flatMap { cask in
            values.filter { $0.kind == .appBundle && AppBundleInventory.isVerifiedCaskLink(cask: cask, appBundle: $0) }.map(\.identity)
        })
        let normalized = values.filter { !linkedBundleIDs.contains($0.identity) }
        return InventorySnapshot(installations: normalized.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }, managers: Array(managers.values).sorted { $0.kind.rawValue < $1.kind.rawValue }, coverage: Array(coverage.values).sorted { $0.id < $1.id }, updateChecks: checks.filter { !linkedBundleIDs.contains($0.installationID) })
    }

    public func prepare(operation: ManagedOperation, installationID: InstallationID) async -> PlanDecision {
        let snapshot = await currentSnapshot()
        guard let installation = snapshot.installations.first(where: { $0.identity == installationID }) else { return .blocked(reason: "This installation is not in the current inventory. Refresh and select it again.") }
        guard !installation.isProtected else { return .blocked(reason: installation.protectionReason ?? "Protected software cannot be changed here.") }
        guard !installation.isStale else { return .guidance(genericGuidance(for: installation), reason: "This inventory row is stale. Refresh before reviewing an action.") }
        guard let manager = snapshot.managers.first(where: { $0.id == installation.identity.managerID }) else { return .guidance(genericGuidance(for: installation), reason: "The owning manager is unavailable.") }
        guard let adapter = adapters.first(where: { $0.kind == manager.kind }) else { return .guidance(genericGuidance(for: installation), reason: "No supported adapter is registered for this source.") }
        let decision = await adapter.prepare(operation: operation, installation: installation, using: runner)
        guard case let .ready(plan) = decision else { return decision }
        let capabilityAllowed = operation == .remove ? installation.removalSupported && manager.removalSupported : installation.updateSupported && manager.updateSupported
        guard manager.presence == .present, installation.ownership == .verified, capabilityAllowed,
              plan.installationID == installation.identity, plan.managerInstanceID == manager.id,
              plan.command.executablePath == manager.executablePath, plan.executableFingerprint == manager.executableFingerprint,
              !plan.privilegeRequired else { return .blocked(reason: "This action is not verified for the current manager, scope, target, and capability.") }
        plans[plan.id] = plan
        return .ready(plan)
    }

    /// Executes only a previously prepared, explicitly confirmed plan, then verifies against its original scope.
    public func execute(planID: UUID, confirmed: Bool) async -> TaskRecord {
        guard !Task.isCancelled else { return immediateRecord(planID: planID, state: .invalidated, summary: "Cancelled before target validation.") }
        guard let plan = plans[planID] else { return immediateRecord(planID: planID, state: .invalidated, summary: "Plan is missing or expired; prepare a new review.") }
        guard confirmed else { return immediateRecord(plan: plan, state: .invalidated, summary: "The operation was not confirmed.") }
        guard !activePlanIDs.contains(planID) else { return immediateRecord(plan: plan, state: .invalidated, summary: "This operation is already running.") }
        guard plan.expiresAt > .now else { plans.removeValue(forKey: planID); return immediateRecord(plan: plan, state: .invalidated, summary: "The review expired; prepare a new review.") }

        let snapshot = await currentSnapshot()
        let manager = snapshot.managers.first(where: { $0.id == plan.installationID.managerID })
        let rootKey = manager?.scope.canonicalRoot ?? "\(plan.installationID.managerID)|\(plan.installationID.scopeID)"
        guard !lockedRoots.contains(rootKey) else { return immediateRecord(plan: plan, state: .invalidated, summary: "Another operation is using this manager scope.") }
        guard let manager, let adapter = adapters.first(where: { $0.kind == manager.kind }), manager.presence == .present,
              let installation = snapshot.installations.first(where: { $0.identity == plan.installationID && !$0.isStale }) else {
            plans.removeValue(forKey: planID); return immediateRecord(plan: plan, state: .invalidated, summary: "The target or adapter is no longer available.")
        }

        plans.removeValue(forKey: planID); activePlanIDs.insert(planID); lockedRoots.insert(rootKey)
        await invalidateScope(manager: manager, rootKey: rootKey)
        var record = TaskRecord(planID: plan.id, installationID: plan.installationID, operation: plan.operation, state: .running, redactedSummary: "Starting the reviewed operation.")
        await store.appendTask(record); publish(.operationChanged(record))
        guard !Task.isCancelled else {
            record.state = .invalidated; record.completedAt = .now; record.redactedSummary = "Cancelled before target revalidation or command launch."
            activePlanIDs.remove(planID)
            await store.appendTask(record); publish(.operationChanged(record)); await reinventoryScope(adapter: adapter, manager: manager, rootKey: rootKey)
            lockedRoots.remove(rootKey)
            return record
        }
        let preflight = await adapter.revalidate(plan: plan, installation: installation, using: runner)
        if Task.isCancelled {
            record.state = .invalidated; record.completedAt = .now; record.redactedSummary = "Cancelled before the command launched."
            activePlanIDs.remove(planID)
            await store.appendTask(record); publish(.operationChanged(record)); await reinventoryScope(adapter: adapter, manager: manager, rootKey: rootKey)
            lockedRoots.remove(rootKey)
            return record
        }
        guard case let .valid(targetFingerprint, executableFingerprint) = preflight,
              targetFingerprint == plan.targetFingerprint, executableFingerprint == plan.executableFingerprint else {
            activePlanIDs.remove(planID)
            record.state = .invalidated; record.completedAt = .now; record.redactedSummary = "The target or manager changed after review. Prepare a new review."
            await store.appendTask(record); publish(.operationChanged(record)); await reinventoryScope(adapter: adapter, manager: manager, rootKey: rootKey); lockedRoots.remove(rootKey); return record
        }

        var launchAttempted = false
        do {
            guard !Task.isCancelled else { throw ProcessRunnerError.cancelledBeforeLaunch }
            launchAttempted = true
            let result = try await runner.run(plan.command)
            record.exitCode = result.exitCode; record.state = .verifying; record.redactedSummary = "The command finished; checking the same manager scope."
            await store.appendTask(record); publish(.operationChanged(record))
            record.verification = await verifyWithoutCallerCancellation(adapter: adapter, plan: plan, installation: installation)
            if plan.operation == .remove && record.verification == .verifiedRemoved || plan.operation == .update && record.verification == .verifiedUpdated {
                record.state = .succeeded; record.redactedSummary = "The manager's inventory confirms the requested change."
            } else if result.wasCancelled || result.didTimeOut { record.state = .outcomeUnknown; record.redactedSummary = "The operation was interrupted. Check the installation state before retrying." }
            else if result.exitCode == 0 {
                record.state = .outcomeUnknown; record.redactedSummary = "The command completed, but the manager could not confirm the requested change."
            } else {
                record.state = .failed; record.redactedSummary = "The manager reported failure; the installation was checked again."
            }
        } catch {
            let processMayHaveLaunched: Bool
            if let runnerError = error as? ProcessRunnerError {
                if case .waitFailed = runnerError { processMayHaveLaunched = true } else { processMayHaveLaunched = false }
            } else { processMayHaveLaunched = launchAttempted }
            if !processMayHaveLaunched {
                record.state = .invalidated; record.redactedSummary = "The command was rejected before launch."
            } else {
                record.state = .verifying; record.redactedSummary = "The process ended unexpectedly; checking the installation state."
                record.verification = await verifyWithoutCallerCancellation(adapter: adapter, plan: plan, installation: installation)
                record.state = (plan.operation == .remove && record.verification == .verifiedRemoved) || (plan.operation == .update && record.verification == .verifiedUpdated) ? .succeeded : .outcomeUnknown
                if record.state == .succeeded { record.redactedSummary = "The manager's inventory confirms the requested change." }
                else { record.redactedSummary = "The operation outcome is uncertain; check the installation state before retrying." }
            }
        }
        record.completedAt = .now; activePlanIDs.remove(planID)
        await store.appendTask(record); publish(.operationChanged(record))
        await reinventoryScope(adapter: adapter, manager: manager, rootKey: rootKey)
        lockedRoots.remove(rootKey)
        return record
    }

    private func invalidateScope(manager: ManagerInstance, rootKey: String) async {
        var snapshot = await currentSnapshot()
        let affected = Set(snapshot.installations.filter { item in
            guard let owner = snapshot.managers.first(where: { $0.id == item.identity.managerID }) else { return item.identity.managerID == manager.id }
            return owner.id == manager.id || owner.scope.canonicalRoot == rootKey
        }.map(\.identity))
        for index in snapshot.installations.indices where affected.contains(snapshot.installations[index].identity) { snapshot.installations[index].isStale = true }
        snapshot.updateChecks.removeAll { affected.contains($0.installationID) }
        cachedSnapshot = snapshot; await store.saveSnapshot(snapshot); publish(.inventoryChanged(snapshot))
    }

    private func reinventoryScope(adapter: any PackageManagerAdapter, manager: ManagerInstance, rootKey: String) async {
        let result = await Task.detached(priority: .utility) { await adapter.inventory(instance: manager, using: self.runner) }.value
        var snapshot = await currentSnapshot()
        let affectedIDs = Set(snapshot.installations.filter { item in
            guard let owner = snapshot.managers.first(where: { $0.id == item.identity.managerID }) else { return item.identity.managerID == manager.id }
            return owner.id == manager.id || owner.scope.canonicalRoot == rootKey
        }.map(\.identity))
        if result.coverage.state == .complete {
            snapshot.installations.removeAll { $0.identity.managerID == manager.id && $0.identity.scopeID == manager.scope.id }
            for index in snapshot.installations.indices where affectedIDs.contains(snapshot.installations[index].identity) { snapshot.installations[index].isStale = true }
            for var item in result.installations { item.isStale = false; snapshot.installations.append(item) }
        } else {
            for index in snapshot.installations.indices where affectedIDs.contains(snapshot.installations[index].identity) { snapshot.installations[index].isStale = true }
            for item in result.installations {
                var fresh = item; fresh.isStale = false
                snapshot.installations.removeAll { $0.identity == fresh.identity }; snapshot.installations.append(fresh)
            }
        }
        snapshot.coverage.removeAll { $0.id == result.coverage.id }; snapshot.coverage.append(result.coverage)
        snapshot.updateChecks.removeAll { check in affectedIDs.contains(check.installationID) || result.installations.contains(where: { $0.identity == check.installationID }) }
        let managers = Dictionary(uniqueKeysWithValues: snapshot.managers.map { ($0.id, $0) })
        let rows = Dictionary(uniqueKeysWithValues: snapshot.installations.map { ($0.identity, $0) })
        let coverage = Dictionary(uniqueKeysWithValues: snapshot.coverage.map { ($0.id, $0) })
        snapshot = makeSnapshot(managers: managers, rows: rows, coverage: coverage, checks: snapshot.updateChecks)
        cachedSnapshot = snapshot; await store.saveSnapshot(snapshot); publish(.inventoryChanged(snapshot))
    }

    public func checkUpdate(installationID: InstallationID) async -> UpdateCheckResult {
        let snapshot = await currentSnapshot()
        guard let installation = snapshot.installations.first(where: { $0.identity == installationID }) else {
            return UpdateCheckResult(installationID: installationID, status: .unknown, explanation: "The installation is not in the current inventory.")
        }
        guard !installation.isStale else {
            let result = UpdateCheckResult(installationID: installationID, status: .unknown, currentVersion: installation.version, explanation: "Refresh this installation before checking for updates.")
            await saveUpdateCheck(result); return result
        }
        guard let manager = snapshot.managers.first(where: { $0.id == installationID.managerID }), manager.presence == .present,
              let adapter = adapters.first(where: { $0.kind == manager.kind }), installation.updateSupported, manager.updateSupported else {
            let result = UpdateCheckResult(installationID: installationID, status: .unsupported, currentVersion: installation.version, explanation: "No validated update check is available for this installation.")
            await saveUpdateCheck(result); return result
        }
        var result = await adapter.checkUpdate(installation: installation, using: runner)
        if result.installationID != installationID {
            result = UpdateCheckResult(installationID: installationID, status: .unknown, currentVersion: installation.version, explanation: "The adapter returned an update result for a different installation.")
        }
        result.explanation = result.explanation.map(PrivacyRedactor.redact)
        await saveUpdateCheck(result); return result
    }

    private func saveUpdateCheck(_ result: UpdateCheckResult) async {
        var snapshot = await currentSnapshot()
        snapshot.updateChecks.removeAll { $0.installationID == result.installationID }
        snapshot.updateChecks.append(result)
        snapshot.updateChecks.sort { $0.installationID.description < $1.installationID.description }
        cachedSnapshot = snapshot; await store.saveSnapshot(snapshot); publish(.inventoryChanged(snapshot))
    }

    private func verifyWithoutCallerCancellation(adapter: any PackageManagerAdapter, plan: ActionPlan, installation: Installation) async -> VerificationResult {
        await Task.detached(priority: .utility) { await adapter.verify(plan: plan, installation: installation, using: self.runner) }.value
    }

    private func cachedManagerKind(for managerID: String) -> ManagerKind? { cachedSnapshot?.managers.first(where: { $0.id == managerID })?.kind }
    private func genericGuidance(for installation: Installation) -> RemovalGuidance {
        RemovalGuidance(title: "Review removal with the source", steps: ["Confirm the source and exact installation path.", "Use the source's documented removal procedure.", "Refresh AppHarbor to check the same installation."], isVerified: false)
    }
    private func immediateRecord(plan: ActionPlan, state: TaskState, summary: String) -> TaskRecord {
        TaskRecord(planID: plan.id, installationID: plan.installationID, operation: plan.operation, state: state, completedAt: .now, redactedSummary: summary)
    }
    private func immediateRecord(planID: UUID, state: TaskState, summary: String) -> TaskRecord {
        TaskRecord(planID: planID, installationID: InstallationID(managerID: "", scopeID: "", nativeID: "", canonicalLocation: ""), operation: .remove, state: state, completedAt: .now, redactedSummary: summary)
    }
    private func publish(_ event: EngineEvent) { for continuation in subscribers.values { continuation.yield(event) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
