import XCTest
@testable import AppHarborCore

private actor CountingRunner: ProcessRunning {
    private var invocationCount = 0
    private let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        invocationCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        return ProcessResult(standardOutput: "", standardError: "", exitCode: 0)
    }
    func count() -> Int { invocationCount }
}

private actor MutableAdapter: PackageManagerAdapter {
    let kind: ManagerKind = .homebrew
    private(set) var detection: DetectionResult
    private var result: AdapterInventoryResult
    private var preflight: PreflightResult = .valid(currentTargetFingerprint: "target", currentExecutableFingerprint: "exec")
    private var verification: VerificationResult = .verifiedRemoved
    private var update: UpdateStatus = .updateAvailable
    private var inventoryCallCount = 0
    private var preflightCallCount = 0
    private var inventoryDelay: Duration = .zero
    init(manager: ManagerInstance, inventory: AdapterInventoryResult) {
        detection = DetectionResult(presence: .present, instances: [manager]); result = inventory
    }
    func setDetection(_ value: DetectionResult) { detection = value }
    func setInventory(_ value: AdapterInventoryResult) { result = value }
    func setPreflight(_ value: PreflightResult) { preflight = value }
    func setVerification(_ value: VerificationResult) { verification = value }
    func setUpdate(_ value: UpdateStatus) { update = value }
    func setInventoryDelay(_ value: Duration) { inventoryDelay = value }
    func detect(using runner: any ProcessRunning) async -> DetectionResult { detection }
    func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        inventoryCallCount += 1
        if inventoryDelay != .zero { try? await Task.sleep(for: inventoryDelay) }
        return result
    }
    func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        let plan = ActionPlan(installationID: installation.identity, operation: operation, managerInstanceID: installation.identity.managerID,
            command: ProcessCommand(executablePath: "/usr/bin/true", arguments: ["uninstall", installation.identity.nativeID]),
            executableFingerprint: "exec", targetFingerprint: "target", previewCommand: "/usr/bin/true uninstall \(installation.identity.nativeID)",
            expectedResult: "The item is removed.")
        return .ready(plan)
    }
    func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult { preflightCallCount += 1; return preflight }
    func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult { verification }
    func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        UpdateCheckResult(installationID: installation.identity, status: update, currentVersion: installation.version, availableVersion: update == .updateAvailable ? "2.0" : nil)
    }
    func inventoryCalls() -> Int { inventoryCallCount }
    func preflightCalls() -> Int { preflightCallCount }
}

private struct StaticFixtureAdapter: PackageManagerAdapter {
    let kind: ManagerKind
    let manager: ManagerInstance
    let rows: [Installation]
    func detect(using runner: any ProcessRunning) async -> DetectionResult { DetectionResult(presence: .present, instances: [manager]) }
    func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        AdapterInventoryResult(installations: rows, coverage: CoverageSnapshot(id: manager.id, sourceName: manager.kind.rawValue, scopeID: manager.scope.id, state: .complete, itemCount: rows.count))
    }
    func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision { .blocked(reason: "Fixture adapter does not mutate.") }
    func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult { .invalidated(reason: "Fixture adapter does not mutate.") }
    func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult { .notAttempted }
}

final class CoreEngineAndStoreTests: XCTestCase {
    private func fixture(version: String = "1.0", name: String = "alpha", managerPresence: ManagerPresence = .present) -> (ManagerInstance, Installation, AdapterInventoryResult) {
        let scope = ManagerScope(id: "/tmp/appharbor-fixture", displayName: "Fixture root", canonicalRoot: "/tmp/appharbor-fixture")
        let manager = ManagerInstance(id: "fixture-brew", kind: .homebrew, executablePath: "/usr/bin/true", executableFingerprint: "exec", version: "4.0", scope: scope, presence: managerPresence, removalSupported: true, updateSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: scope.id, nativeID: name, canonicalLocation: "/tmp/appharbor-fixture/Cellar/\(name)/\(version)")
        let installation = Installation(identity: identity, kind: .formula, displayName: name, version: version, canonicalLocation: identity.canonicalLocation, ownership: .verified, removalSupported: true, updateSupported: true)
        let coverage = CoverageSnapshot(id: manager.id, sourceName: "Fixture", scopeID: scope.id, state: .complete, itemCount: 1)
        return (manager, installation, AdapterInventoryResult(installations: [installation], coverage: coverage))
    }

    private func makeEngine(_ inventory: AdapterInventoryResult, delay: Duration = .zero) -> (AppHarborCoreEngine, MutableAdapter, CountingRunner) {
        let (manager, _, _) = fixture()
        let adapter = MutableAdapter(manager: manager, inventory: inventory)
        let runner = CountingRunner(delay: delay)
        let engine = AppHarborCoreEngine(adapters: [adapter], runner: runner, store: InMemoryInstallationStore())
        return (engine, adapter, runner)
    }

    func testUnconfirmedPlanDoesNotRunAndConsumedPlanCannotReplay() async throws {
        let (_, item, inventory) = fixture()
        let (engine, _, runner) = makeEngine(inventory)
        let snapshot = await engine.refresh()
        let decision = await engine.prepare(operation: .remove, installationID: item.identity)
        guard case .ready(let plan) = decision else { return XCTFail("expected a plan") }
        let refused = await engine.execute(planID: plan.id, confirmed: false)
        XCTAssertEqual(refused.state, .invalidated)
        let deniedRunCount = await runner.count()
        XCTAssertEqual(deniedRunCount, 0)
        let completed = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(completed.state, .succeeded)
        let replay = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(replay.state, .invalidated)
        let completedRunCount = await runner.count()
        XCTAssertEqual(completedRunCount, 1)
        XCTAssertEqual(snapshot.installations.count, 1)
    }

    func testStalePreflightBlocksExecution() async throws {
        let (_, item, inventory) = fixture()
        let (engine, adapter, runner) = makeEngine(inventory)
        _ = await engine.refresh()
        await adapter.setPreflight(.invalidated(reason: "target changed"))
        guard case .ready(let plan) = await engine.prepare(operation: .remove, installationID: item.identity) else { return XCTFail("expected plan") }
        let record = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(record.state, .invalidated)
        let runCount = await runner.count()
        XCTAssertEqual(runCount, 0)
    }

    func testPartialCoverageKeepsUnseenRowsStaleAndMissingManagerUnavailable() async throws {
        let (manager, item, inventory) = fixture()
        let (engine, adapter, _) = makeEngine(inventory)
        _ = await engine.refresh()
        let secondID = InstallationID(managerID: manager.id, scopeID: manager.scope.id, nativeID: "beta", canonicalLocation: "/tmp/appharbor-fixture/Cellar/beta/2")
        let second = Installation(identity: secondID, kind: .formula, displayName: "beta", version: "2", canonicalLocation: secondID.canonicalLocation, ownership: .verified)
        await adapter.setInventory(AdapterInventoryResult(installations: [second], coverage: CoverageSnapshot(id: manager.id, sourceName: "Fixture", scopeID: manager.scope.id, state: .partial, itemCount: 1, warning: "permission denied")))
        let partial = await engine.refresh()
        XCTAssertTrue(partial.installations.first(where: { $0.identity == item.identity })?.isStale == true)
        XCTAssertTrue(partial.installations.first(where: { $0.identity == second.identity })?.isStale == false)
        await adapter.setDetection(DetectionResult(presence: .absent))
        let missing = await engine.refresh()
        XCTAssertEqual(missing.managers.first(where: { $0.id == manager.id })?.presence, .absent)
        XCTAssertTrue(missing.installations.allSatisfy(\.isStale))
    }

    func testDisappearedManagerInstanceIsUnavailableWhenSiblingInstanceRemains() async throws {
        let (manager1, item1, inventory1) = fixture()
        let scope2 = ManagerScope(id: "/tmp/appharbor-second-prefix", displayName: "Second prefix", canonicalRoot: "/tmp/appharbor-second-prefix")
        let manager2 = ManagerInstance(id: "fixture-brew-second", kind: .homebrew, executablePath: "/usr/bin/true", executableFingerprint: "exec2", scope: scope2, removalSupported: true)
        let item2ID = InstallationID(managerID: manager2.id, scopeID: scope2.id, nativeID: "gamma", canonicalLocation: "/tmp/appharbor-second-prefix/Cellar/gamma/1")
        let item2 = Installation(identity: item2ID, kind: .formula, displayName: "gamma", version: "1", canonicalLocation: item2ID.canonicalLocation, ownership: .verified)
        let (engine, adapter, _) = makeEngine(inventory1)
        _ = await engine.refresh()
        await adapter.setDetection(DetectionResult(presence: .present, instances: [manager2]))
        await adapter.setInventory(AdapterInventoryResult(installations: [item2], coverage: CoverageSnapshot(id: manager2.id, sourceName: "Fixture", scopeID: scope2.id, state: .complete, itemCount: 1)))
        let refreshed = await engine.refresh()
        XCTAssertEqual(refreshed.managers.first(where: { $0.id == manager1.id })?.presence, .unavailable)
        XCTAssertTrue(refreshed.installations.first(where: { $0.identity == item1.identity })?.isStale == true)
        XCTAssertEqual(refreshed.managers.first(where: { $0.id == manager2.id })?.presence, .present)
        XCTAssertTrue(refreshed.installations.first(where: { $0.identity == item2.identity })?.isStale == false)
    }

    func testTwoActionsForSameCanonicalRootAreSerialized() async throws {
        let (manager, first, _) = fixture()
        let secondID = InstallationID(managerID: manager.id, scopeID: manager.scope.id, nativeID: "beta", canonicalLocation: "/tmp/appharbor-fixture/Cellar/beta/1")
        let second = Installation(identity: secondID, kind: .formula, displayName: "beta", version: "1", canonicalLocation: secondID.canonicalLocation, ownership: .verified, removalSupported: true)
        let inventory = AdapterInventoryResult(installations: [first, second], coverage: CoverageSnapshot(id: manager.id, sourceName: "Fixture", scopeID: manager.scope.id, state: .complete, itemCount: 2))
        let (engine, _, runner) = makeEngine(inventory, delay: .milliseconds(350))
        _ = await engine.refresh()
        guard case .ready(let plan1) = await engine.prepare(operation: .remove, installationID: first.identity),
              case .ready(let plan2) = await engine.prepare(operation: .remove, installationID: second.identity) else { return XCTFail("expected plans") }
        let firstTask = Task { await engine.execute(planID: plan1.id, confirmed: true) }
        try await Task.sleep(for: .milliseconds(100))
        let secondRecord = await engine.execute(planID: plan2.id, confirmed: true)
        XCTAssertEqual(secondRecord.state, .invalidated)
        let firstResult = await firstTask.value
        let runCount = await runner.count()
        XCTAssertEqual(firstResult.state, .succeeded)
        XCTAssertEqual(runCount, 1)
    }

    func testUpdateCandidateExpiresWhenInstalledVersionChanges() async throws {
        let (manager, item, initial) = fixture()
        let (engine, adapter, _) = makeEngine(initial)
        _ = await engine.refresh()
        let candidate = await engine.checkUpdate(installationID: item.identity)
        XCTAssertEqual(candidate.status, .updateAvailable)
        await adapter.setInventory(fixture(version: "2.0").2)
        let refreshed = await engine.refresh()
        XCTAssertTrue(refreshed.updateChecks.isEmpty)
        XCTAssertEqual(refreshed.managers.first?.id, manager.id)
    }

    func testPreCancelledActionSkipsPreflightAndLaunch() async throws {
        let (_, item, inventory) = fixture()
        let (engine, adapter, runner) = makeEngine(inventory)
        _ = await engine.refresh()
        guard case .ready(let plan) = await engine.prepare(operation: .remove, installationID: item.identity) else { return XCTFail("expected plan") }
        let task = Task { await Task.yield(); return await engine.execute(planID: plan.id, confirmed: true) }
        task.cancel()
        let record = await task.value
        XCTAssertEqual(record.state, .invalidated)
        let preflightCalls = await adapter.preflightCalls()
        let runnerCalls = await runner.count()
        XCTAssertEqual(preflightCalls, 0)
        XCTAssertEqual(runnerCalls, 0)
    }

    func testActionInvalidatesChecksAndPublishesSameScopeInventoryAfterOutcome() async throws {
        let (_, item, inventory) = fixture()
        let (engine, adapter, _) = makeEngine(inventory)
        _ = await engine.refresh()
        let update = await engine.checkUpdate(installationID: item.identity)
        XCTAssertEqual(update.status, .updateAvailable)
        guard case .ready(let plan) = await engine.prepare(operation: .remove, installationID: item.identity) else { return XCTFail("expected plan") }
        let record = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(record.state, .succeeded)
        let refreshed = await engine.currentSnapshot()
        XCTAssertTrue(refreshed.updateChecks.isEmpty)
        XCTAssertFalse(refreshed.installations.first(where: { $0.identity == item.identity })?.isStale ?? true)
        let calls = await adapter.inventoryCalls()
        XCTAssertEqual(calls, 2, "the action should publish a same-scope inventory after its outcome")
    }

    func testPartialPostActionInventoryPreservesUnseenRowsAsStale() async throws {
        let (manager, first, _) = fixture()
        let secondID = InstallationID(managerID: manager.id, scopeID: manager.scope.id, nativeID: "beta", canonicalLocation: "/tmp/appharbor-fixture/Cellar/beta/1")
        let second = Installation(identity: secondID, kind: .formula, displayName: "beta", version: "1", canonicalLocation: secondID.canonicalLocation, ownership: .verified, removalSupported: true)
        let initial = AdapterInventoryResult(installations: [first, second], coverage: CoverageSnapshot(id: manager.id, sourceName: "Fixture", scopeID: manager.scope.id, state: .complete, itemCount: 2))
        let (engine, adapter, _) = makeEngine(initial)
        _ = await engine.refresh()
        guard case .ready(let plan) = await engine.prepare(operation: .remove, installationID: first.identity) else { return XCTFail("expected plan") }
        await adapter.setInventory(AdapterInventoryResult(installations: [second], coverage: CoverageSnapshot(id: manager.id, sourceName: "Fixture", scopeID: manager.scope.id, state: .partial, itemCount: 1, warning: "fixture partial")))
        let record = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(record.state, .succeeded)
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.installations.first(where: { $0.identity == first.identity })?.isStale == true)
        XCTAssertTrue(snapshot.installations.first(where: { $0.identity == second.identity })?.isStale == false)
    }

    func testCanonicalRootRemainsLockedUntilPostActionInventoryCompletes() async throws {
        let (_, first, _) = fixture()
        let secondID = InstallationID(managerID: first.identity.managerID, scopeID: first.identity.scopeID, nativeID: "beta", canonicalLocation: "/tmp/appharbor-fixture/Cellar/beta/1")
        let second = Installation(identity: secondID, kind: .formula, displayName: "beta", version: "1", canonicalLocation: secondID.canonicalLocation, ownership: .verified, removalSupported: true)
        let expanded = AdapterInventoryResult(installations: [first, second], coverage: CoverageSnapshot(id: first.identity.managerID, sourceName: "Fixture", scopeID: first.identity.scopeID, state: .complete, itemCount: 2))
        let (engine, adapter, _) = makeEngine(expanded)
        _ = await engine.refresh()
        guard case .ready(let plan1) = await engine.prepare(operation: .remove, installationID: first.identity),
              case .ready(let plan2) = await engine.prepare(operation: .remove, installationID: second.identity) else { return XCTFail("expected plans") }
        await adapter.setInventoryDelay(.milliseconds(400))
        let firstTask = Task { await engine.execute(planID: plan1.id, confirmed: true) }
        try await Task.sleep(for: .milliseconds(180))
        let secondResult = await engine.execute(planID: plan2.id, confirmed: true)
        XCTAssertEqual(secondResult.state, .invalidated)
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult.state, .succeeded)
    }

    func testVerifiedCaskAppLinkIsPresentedOnceUnderCaskOwnership() async throws {
        let appPath = "/tmp/appharbor-fixture/Applications/Widget.app"
        let caskScope = ManagerScope(id: "/tmp/appharbor-fixture", displayName: "Fixture brew", canonicalRoot: "/tmp/appharbor-fixture")
        let appScope = ManagerScope(id: "/tmp/appharbor-fixture/Applications", displayName: "Applications", canonicalRoot: "/tmp/appharbor-fixture/Applications")
        let caskManager = ManagerInstance(id: "cask-fixture", kind: .homebrew, executablePath: "/usr/bin/true", executableFingerprint: "brew", scope: caskScope, removalSupported: true)
        let appManager = ManagerInstance(id: "apps-fixture", kind: .appBundle, executablePath: "/usr/bin/true", executableFingerprint: "metadata", scope: appScope)
        let caskID = InstallationID(managerID: caskManager.id, scopeID: caskScope.id, nativeID: "widget", canonicalLocation: "/tmp/appharbor-fixture/Caskroom/widget/1")
        let appID = InstallationID(managerID: appManager.id, scopeID: appScope.id, nativeID: "com.example.widget", canonicalLocation: appPath)
        let cask = Installation(identity: caskID, kind: .cask, displayName: "Widget", version: "1", canonicalLocation: caskID.canonicalLocation, ownership: .verified, evidence: [ManagerEvidence(label: "Bundle path", value: appPath)], removalSupported: true)
        let app = Installation(identity: appID, kind: .appBundle, displayName: "Widget", version: "1", canonicalLocation: appPath, bundleIdentifier: "com.example.widget", ownership: .strong)
        let adapters: [any PackageManagerAdapter] = [
            StaticFixtureAdapter(kind: .homebrew, manager: caskManager, rows: [cask]),
            StaticFixtureAdapter(kind: .appBundle, manager: appManager, rows: [app])
        ]
        let engine = AppHarborCoreEngine(adapters: adapters, runner: CountingRunner(), store: InMemoryInstallationStore())
        let snapshot = await engine.refresh()
        XCTAssertEqual(snapshot.installations.count, 1)
        XCTAssertEqual(snapshot.installations.first?.identity, caskID)
        XCTAssertEqual(snapshot.installations.first?.kind, .cask)
    }

    func testDurableStoreMarksRestartedWorkUnknownAndCachedRowsStale() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-store-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let (manager, item, _) = fixture()
        let first = LocalJSONInstallationStore(fileURL: fileURL)
        await first.saveSnapshot(InventorySnapshot(installations: [item], managers: [manager], coverage: []))
        var record = TaskRecord(planID: UUID(), installationID: item.identity, operation: .remove, state: .running, redactedSummary: "running")
        await first.appendTask(record)
        record.state = .verifying
        await first.appendTask(record)
        let liveTasks = await first.loadTasks()
        XCTAssertEqual(liveTasks.first?.state, .verifying, "live work must not be normalized before restart")
        let reopened = LocalJSONInstallationStore(fileURL: fileURL)
        let reopenedTasks = await reopened.loadTasks()
        let reopenedSnapshot = await reopened.loadSnapshot()
        XCTAssertEqual(reopenedTasks.count, 1)
        XCTAssertEqual(reopenedTasks.first?.state, .outcomeUnknown)
        XCTAssertTrue(reopenedSnapshot.installations.first?.isStale == true)
    }

    func testStoreRetentionUpsertsAndRedactsSecretsAndPreservesCorruption() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = base.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = LocalJSONInstallationStore(fileURL: fileURL)
        let (manager, baseItem, _) = fixture()
        var item = baseItem
        item.version = "https://registry.example/package?token=versionSecret"
        item.bundleIdentifier = "https://registry.example/app?token=bundleSecret"
        item.protectionReason = "https://registry.example/reason?token=protectionSecret"
        item.evidence = [ManagerEvidence(label: "https://registry.example/label?token=labelSecret", value: "https://registry.example/evidence?token=evidenceSecret")]
        var managerWithSecrets = manager
        managerWithSecrets.version = "https://registry.example/manager?token=managerVersionSecret"
        managerWithSecrets.architecture = "https://registry.example/arch?token=architectureSecret"
        managerWithSecrets.scope.displayName = "https://registry.example/scope?token=scopeSecret"
        var task = TaskRecord(planID: UUID(), installationID: item.identity, operation: .remove, state: .running, redactedSummary: "Bearer abc123")
        await store.appendTask(task)
        task.state = .succeeded; task.redactedSummary = "done https://user:pw@registry.example/pkg?token=topsecret"
        await store.appendTask(task)
        for index in 0..<205 {
            let unique = TaskRecord(planID: UUID(), installationID: item.identity, operation: .remove, state: .failed, startedAt: Date().addingTimeInterval(Double(index)), redactedSummary: "task")
            await store.appendTask(unique)
        }
        let retainedTasks = await store.loadTasks()
        XCTAssertEqual(retainedTasks.count, 200)
        await store.saveSnapshot(InventorySnapshot(installations: [item], managers: [managerWithSecrets], coverage: [], updateChecks: [UpdateCheckResult(installationID: item.identity, status: .failed, currentVersion: "https://registry.example/current?token=currentVersionSecret", availableVersion: "https://registry.example/available?token=availableVersionSecret", explanation: "https://user:pw@registry.example/?token=topsecret")]))
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("topsecret")); XCTAssertFalse(text.contains("user:pw")); XCTAssertTrue(text.contains("REDACTED"))
        for secret in ["versionSecret", "bundleSecret", "protectionSecret", "labelSecret", "evidenceSecret", "managerVersionSecret", "architectureSecret", "scopeSecret", "currentVersionSecret", "availableVersionSecret"] {
            XCTAssertFalse(text.contains(secret), "untrusted inventory metadata must be redacted before persistence")
        }

        let brokenURL = base.appendingPathComponent("broken.json")
        let invalid = Data("{not-json".utf8); try invalid.write(to: brokenURL)
        let broken = LocalJSONInstallationStore(fileURL: brokenURL)
        _ = await broken.loadSnapshot(); await broken.saveSnapshot(InventorySnapshot(installations: [], managers: [], coverage: []))
        let brokenStatus = await broken.storageStatus()
        XCTAssertTrue(ifCaseReadFailure(brokenStatus), "corrupt cache status should be visible, got \(brokenStatus)")
        XCTAssertEqual(try Data(contentsOf: brokenURL), invalid)
    }
}

private func ifCaseReadFailure(_ status: StorageStatus) -> Bool { if case .readFailure = status { return true }; return false }
