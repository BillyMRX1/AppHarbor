import AppHarborCore
@testable import AppHarborMCPBridge
import Foundation
import XCTest
@testable import AppHarbor

@MainActor
final class MCPReviewTests: XCTestCase {
    func testDisablingActionRequestsInvalidatesCapturedPlanBeforeExecution() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)

        fixture.model.mcpActionRequestsEnabled = false
        await fixture.model.execute(plan)

        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertNil(fixture.model.planDecision)
    }

    func testDismissedReviewCannotExecuteCapturedPlan() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)
        XCTAssertEqual(fixture.model.reviewInstallation?.identity, fixture.installation.identity)

        fixture.model.shortcutMessage = "Test-only current sheet error"
        fixture.model.planDecisionSheetDidPresent()
        fixture.model.planDecision = nil
        XCTAssertNil(fixture.model.shortcutMessage)
        fixture.model.planDecisionSheetDidDismiss()
        XCTAssertNil(fixture.model.reviewInstallation)
        await fixture.model.execute(plan)

        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testRequestReplayReturnsSameReviewAndPayloadReuseIsRejected() async throws {
        let fixture = try await makeFixture()
        let requestID = UUID().uuidString.lowercased()
        let request = MCPBridgeRequest(action: .requestRemoval,
                                       parameters: ["request_id": requestID,
                                                    "installation_id": MCPInventoryPresenter.identifier(for: fixture.installation.identity)])

        let first = await fixture.model.handleMCPRequest(request)
        XCTAssertEqual(try json(first)["status"] as? String, "preparing")
        try await waitForReview(fixture.model)

        let replay = await fixture.model.handleMCPRequest(request)
        XCTAssertEqual(try json(replay)["status"] as? String, "awaiting_confirmation")
        let changedPayload = MCPBridgeRequest(action: .requestUpdate, parameters: request.parameters)
        let rejected = await fixture.model.handleMCPRequest(changedPayload)
        XCTAssertTrue(rejected.isError)
        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testNativeConfirmationRunsOneOperationAndReplayDoesNotRunAgain() async throws {
        let fixture = try await makeFixture()
        let requestID = UUID().uuidString.lowercased()
        let request = removalRequest(requestID: requestID, installation: fixture.installation)
        let prepared = await fixture.model.handleMCPRequest(request)
        XCTAssertEqual(try json(prepared)["status"] as? String, "preparing")
        try await waitForReview(fixture.model)
        guard case let .ready(plan)? = fixture.model.planDecision else { throw TestError.noReviewPlan }

        var unrelatedStaleCallback = plan
        unrelatedStaleCallback.id = UUID()
        await fixture.model.execute(unrelatedStaleCallback)
        let stillAwaiting = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .getRequestStatus,
                                                                                 parameters: ["request_id": requestID]))
        XCTAssertEqual(try json(stillAwaiting)["status"] as? String, "awaiting_confirmation")
        let beforeConfirmation = await fixture.runner.runCount
        XCTAssertEqual(beforeConfirmation, 0)
        await fixture.model.execute(plan)
        let afterConfirmation = await fixture.runner.runCount
        XCTAssertEqual(afterConfirmation, 1)

        let status = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .getRequestStatus,
                                                                           parameters: ["request_id": requestID]))
        let statusJSON = try json(status)
        XCTAssertEqual(statusJSON["status"] as? String, "succeeded")
        XCTAssertEqual(statusJSON["verification"] as? String, VerificationResult.verifiedRemoved.rawValue)
        let replay = await fixture.model.handleMCPRequest(request)
        XCTAssertEqual(try json(replay)["status"] as? String, "succeeded")
        let afterReplay = await fixture.runner.runCount
        XCTAssertEqual(afterReplay, 1)
    }

    func testNativeTrashRequestRequiresReviewAndReplayDoesNotMoveTwice() async throws {
        let fixture = try await makeNativeTrashFixture()
        defer { if let appRoot = fixture.appRoot { try? FileManager.default.removeItem(at: appRoot) } }
        let declinedID = UUID().uuidString.lowercased()
        let declinedRequest = removalRequest(requestID: declinedID, installation: fixture.installation)
        _ = await fixture.model.handleMCPRequest(declinedRequest)
        try await waitForReview(fixture.model)
        guard case let .ready(declinedPlan)? = fixture.model.planDecision,
              case let .appBundleTrash(target) = declinedPlan.execution else {
            throw TestError.noReviewPlan
        }
        XCTAssertEqual(target.appPath, fixture.installation.canonicalLocation)
        XCTAssertNil(declinedPlan.command)
        XCTAssertEqual(fixture.trashExecutor.callCount, 0)

        fixture.model.planDecisionSheetDidPresent()
        fixture.model.planDecision = nil
        fixture.model.planDecisionSheetDidDismiss()
        XCTAssertEqual(fixture.trashExecutor.callCount, 0, "Closing the human review must not move the app.")

        let approvedID = UUID().uuidString.lowercased()
        let approvedRequest = removalRequest(requestID: approvedID, installation: fixture.installation)
        _ = await fixture.model.handleMCPRequest(approvedRequest)
        try await waitForReview(fixture.model)
        guard case let .ready(approvedPlan)? = fixture.model.planDecision,
              case .appBundleTrash = approvedPlan.execution else { throw TestError.noReviewPlan }
        await fixture.model.execute(approvedPlan)
        XCTAssertEqual(fixture.trashExecutor.callCount, 1)

        let replay = await fixture.model.handleMCPRequest(approvedRequest)
        XCTAssertEqual(try json(replay)["status"] as? String, "succeeded")
        XCTAssertEqual(fixture.trashExecutor.callCount, 1, "Replaying a confirmed request must not repeat the Trash operation.")
    }

    func testProtectedAppBundleRemovalGuideKeepsBlockedDecision() async throws {
        let fixture = try await makeNativeTrashFixture(protected: true)
        defer { if let appRoot = fixture.appRoot { try? FileManager.default.removeItem(at: appRoot) } }
        var revealed: URL?
        fixture.model.shortcutService = InstallationShortcutService(reveal: { revealed = $0 }, copy: { _ in })

        XCTAssertFalse(fixture.model.nativeTrashRemovalAvailable(for: fixture.installation))
        await fixture.model.openRemovalGuide(for: fixture.installation)
        fixture.model.selection = [InstallationID(managerID: "another", scopeID: "another", nativeID: "another", canonicalLocation: "/tmp/another.app")]
        fixture.model.showReviewedInstallationInFinder()

        guard case let .blocked(reason)? = fixture.model.planDecision else {
            XCTFail("Protected app bundles must keep the core engine's blocked decision.")
            return
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("protected"))
        XCTAssertEqual(fixture.trashExecutor.callCount, 0)
        XCTAssertEqual(revealed?.path, fixture.installation.canonicalLocation,
                       "Shortcuts in a blocked guide must remain bound to the app reviewed when the guide opened.")
    }

    func testExpiredReviewCannotExecuteCapturedPlan() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)

        fixture.model.expirePendingMCPReviewIfNeeded(now: .distantFuture)
        await fixture.model.execute(plan)

        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testExpiredMCPProvenanceCannotFallThroughBeforeExpiryTaskRuns() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)
        guard let requestID = fixture.model.activeMCPReview?.requestID else {
            throw TestError.noReviewPlan
        }

        // Simulate time advancing while the scheduled expiry task is delayed.
        fixture.model.activeMCPReview?.expiresAt = .distantPast
        fixture.model.mcpPlanProvenance[plan.id] = MCPPlanProvenance(requestID: requestID, expiresAt: .distantPast)
        await fixture.model.execute(plan)

        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertNil(fixture.model.planDecision)
        let status = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .getRequestStatus,
                                                                           parameters: ["request_id": requestID]))
        XCTAssertEqual(try json(status)["status"] as? String, "invalidated")
    }

    func testTurningBridgeOffInvalidatesCapturedPlan() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)

        fixture.model.mcpBridgeEnabled = false
        await fixture.model.execute(plan)

        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testDelayedDismissalCannotStripNewAIPlanProvenance() async throws {
        let fixture = try await makeFixture()
        let plan = try await prepareRemoval(in: fixture)
        let requestID = fixture.model.activeMCPReview?.requestID

        // Models an older sheet's onDismiss arriving after the new AI review is already visible.
        fixture.model.planDecisionSheetDidDismiss()
        XCTAssertNotNil(fixture.model.planDecision)
        XCTAssertEqual(fixture.model.activeMCPReview?.requestID, requestID)

        // Even if review context is lost by a later lifecycle race, an AI-issued plan cannot
        // fall through to the ordinary native-plan execution path.
        fixture.model.activeMCPReview = nil
        await fixture.model.execute(plan)
        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testExpiryWithoutPresentedSheetDoesNotBlockFutureRequests() async throws {
        let fixture = try await makeFixture()
        _ = try await prepareRemoval(in: fixture)
        XCTAssertNil(fixture.model.presentedPlanSheetToken)

        fixture.model.expirePendingMCPReviewIfNeeded(now: .distantFuture)
        XCTAssertFalse(fixture.model.planDecisionSheetDismissalPending)
        let next = await fixture.model.handleMCPRequest(removalRequest(requestID: UUID().uuidString.lowercased(),
                                                                       installation: fixture.installation))
        XCTAssertFalse(next.isError)
        XCTAssertEqual(try json(next)["status"] as? String, "preparing")
    }

    func testBridgeAndActionRequestsDefaultOff() async throws {
        let fixture = try await makeFixture(enableBridge: false, allowActions: false)

        XCTAssertFalse(fixture.model.mcpBridgeEnabled)
        XCTAssertFalse(fixture.model.mcpActionRequestsEnabled)
        XCTAssertEqual(fixture.model.mcpBridgeStatus, "Off")
        let response = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .listSources))
        XCTAssertTrue(response.isError)
    }

    func testReadOnlyMCPInventoryQueriesPaginationDetailAndCoverageArePrivate() async throws {
        let fixture = try await makeFixture(enableBridge: true, allowActions: false)
        let secondIdentity = InstallationID(managerID: fixture.installation.identity.managerID,
                                            scopeID: fixture.installation.identity.scopeID,
                                            nativeID: "private-tool",
                                            canonicalLocation: "\(NSHomeDirectory())/Library/Tools/private-tool")
        let privateInstallation = Installation(identity: secondIdentity, kind: .npmPackage,
                                               displayName: "Private https://user:password@example.test/tool?token=topsecret",
                                               version: "2.0.0", canonicalLocation: secondIdentity.canonicalLocation,
                                               ownership: .verified, removalSupported: true, updateSupported: true)
        let manager = ManagerInstance(id: fixture.installation.identity.managerID, kind: .homebrew,
                                      executablePath: "/opt/homebrew/bin/brew", executableFingerprint: "manager-fingerprint",
                                      scope: ManagerScope(id: fixture.installation.identity.scopeID, displayName: "Homebrew",
                                                          canonicalRoot: "/opt/homebrew"),
                                      removalSupported: true, updateSupported: true)
        let coverage = CoverageSnapshot(id: manager.id, sourceName: "Homebrew", scopeID: manager.scope.id,
                                        state: .complete, itemCount: 2)
        fixture.model.snapshot = InventorySnapshot(installations: [fixture.installation, privateInstallation],
                                                   managers: [manager], coverage: [coverage])

        let paged = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .listInstallations,
                                                                          parameters: ["offset": "1", "limit": "1"]))
        let pageJSON = try json(paged)
        XCTAssertEqual(pageJSON["total"] as? Int, 2)
        let pageItems = try XCTUnwrap(pageJSON["items"] as? [[String: Any]])
        XCTAssertEqual(pageItems.count, 1)
        let privateItem = try XCTUnwrap(pageItems.first)
        let opaqueID = try XCTUnwrap(privateItem["installation_id"] as? String)
        XCTAssertEqual(opaqueID.count, 64)
        XCTAssertTrue(opaqueID.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
        XCTAssertFalse(opaqueID.contains("private-tool"))
        XCTAssertFalse(opaqueID.contains(NSHomeDirectory()))
        XCTAssertEqual(privateItem["path"] as? String, "~/Library/Tools/private-tool")
        XCTAssertFalse(try XCTUnwrap(privateItem["path"] as? String).contains(NSHomeDirectory()))

        let searched = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .listInstallations,
                                                                             parameters: ["query": "Private", "limit": "1"]))
        let searchJSON = try json(searched)
        XCTAssertEqual(searchJSON["total"] as? Int, 1)
        let searchedItem = try XCTUnwrap((searchJSON["items"] as? [[String: Any]])?.first)
        let safeName = try XCTUnwrap(searchedItem["display_name"] as? String)
        XCTAssertTrue(safeName.contains("[REDACTED]@example.test"))
        XCTAssertTrue(safeName.contains("token=[REDACTED]"))
        XCTAssertFalse(safeName.contains("password"))
        XCTAssertFalse(safeName.contains("topsecret"))

        let detail = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .getInstallation,
                                                                           parameters: ["installation_id": opaqueID]))
        let detailJSON = try json(detail)
        XCTAssertEqual((detailJSON["installation"] as? [String: Any])?["installation_id"] as? String, opaqueID)

        let sources = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .listSources))
        let sourcesJSON = try json(sources)
        let sourceItems = try XCTUnwrap(sourcesJSON["sources"] as? [[String: Any]])
        XCTAssertEqual(sourceItems.first?["installation_count"] as? Int, 2)
        let coverageItems = try XCTUnwrap(sourcesJSON["coverage"] as? [[String: Any]])
        XCTAssertEqual(coverageItems.first?["state"] as? String, "complete")
        XCTAssertEqual(coverageItems.first?["installation_count"] as? Int, 2)

        let action = await fixture.model.handleMCPRequest(removalRequest(requestID: UUID().uuidString.lowercased(),
                                                                         installation: privateInstallation))
        XCTAssertTrue(action.isError)
        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertNil(fixture.model.planDecision)
    }

    func testGuidanceOnlyRequestNeverCreatesReadyActionPlan() async throws {
        let fixture = try await makeFixture(guidanceOnly: true)
        let requestID = UUID().uuidString.lowercased()
        let response = await fixture.model.handleMCPRequest(removalRequest(requestID: requestID, installation: fixture.installation))
        XCTAssertEqual(try json(response)["status"] as? String, "preparing")

        try await waitForDecision(fixture.model)
        guard case .guidance? = fixture.model.planDecision else {
            XCTFail("A guidance-only item must never become an executable review plan")
            return
        }
        let status = await fixture.model.handleMCPRequest(MCPBridgeRequest(action: .getRequestStatus,
                                                                           parameters: ["request_id": requestID]))
        XCTAssertEqual(try json(status)["status"] as? String, "guidance")
        let runCount = await fixture.runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testHandlerFromStoppedBridgeSessionCannotStartNewRequestAfterRestart() async throws {
        let fixture = try await makeFixture()
        let oldGeneration = fixture.model.mcpBridgeGeneration
        fixture.model.mcpBridgeEnabled = false
        fixture.model.mcpBridgeEnabled = true

        let request = MCPBridgeRequest(action: .refreshInventory)
        let response = await fixture.model.handleMCPRequest(request, bridgeGeneration: oldGeneration)

        XCTAssertTrue(response.isError)
        XCTAssertFalse(fixture.model.isRefreshing)
        XCTAssertNil(fixture.model.planDecision)
    }

    private struct Fixture {
        let model: LibraryModel
        let installation: Installation
        let runner: FakeRunner
        let trashExecutor: FakeTrashExecutor
        var appRoot: URL? = nil
    }

    private func makeFixture(enableBridge: Bool = true, allowActions: Bool = true, guidanceOnly: Bool = false) async throws -> Fixture {
        let manager = ManagerInstance(id: "test-homebrew", kind: .homebrew,
                                      executablePath: "/opt/homebrew/bin/brew", executableFingerprint: "manager-fingerprint",
                                      scope: ManagerScope(id: "user", displayName: "Homebrew", canonicalRoot: "/opt/homebrew"),
                                      removalSupported: true, updateSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: manager.scope.id, nativeID: "dockside", canonicalLocation: "/opt/homebrew/Caskroom/dockside")
        let installation = Installation(identity: identity, kind: .cask, displayName: "Dockside", version: "1.2.3",
                                         canonicalLocation: identity.canonicalLocation, ownership: .verified,
                                         removalSupported: true, updateSupported: true, isStale: false)
        let snapshot = InventorySnapshot(installations: [installation], managers: [manager],
                                         coverage: [CoverageSnapshot(id: manager.id, sourceName: "Homebrew", scopeID: manager.scope.id,
                                                                     state: .complete, itemCount: 1)])
        let store = InMemoryInstallationStore()
        await store.saveSnapshot(snapshot)
        let runner = FakeRunner()
        let trashExecutor = FakeTrashExecutor()
        let adapter = FakeAdapter(manager: manager, installation: installation, guidanceOnly: guidanceOnly)
        let engine = AppHarborCoreEngine(adapters: [adapter], runner: runner, appTrashExecutor: trashExecutor, store: store)
        _ = await engine.refresh()
        let defaults = UserDefaults(suiteName: "AppHarbor-MCPReviewTests-\(UUID().uuidString)")!
        defaults.set(enableBridge, forKey: "AppHarbor.mcpBridgeEnabled")
        defaults.set(allowActions, forKey: "AppHarbor.mcpActionRequestsEnabled")
        let socketURL = FileManager.default.temporaryDirectory.appendingPathComponent("ah-\(UUID().uuidString).sock")
        let model = LibraryModel(engine: engine, store: store, preferences: defaults,
                                 mcpServer: MCPBridgeServer(socketURL: socketURL), mcpReviewTTL: 300)
        try await waitForSnapshot(model)
        XCTAssertEqual(model.mcpBridgeEnabled, enableBridge)
        XCTAssertEqual(model.mcpActionRequestsEnabled, allowActions)
        return Fixture(model: model, installation: installation, runner: runner, trashExecutor: trashExecutor)
    }

    private func makeNativeTrashFixture(protected: Bool = false) async throws -> Fixture {
        let appRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AppHarbor-NativeTrash-\(UUID().uuidString)", isDirectory: true)
        let appURL = appRoot.appendingPathComponent("OrdinaryApp.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let bundleIdentifier = "test.example.ordinaryapp"
        let info = ["CFBundleIdentifier": bundleIdentifier,
                    "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": "OrdinaryApp",
                    "CFBundleVersion": "1"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let target = try XCTUnwrap(AppBundleTrashTarget.capture(path: appURL.path, scopeRoot: appRoot.path, bundleIdentifier: bundleIdentifier))

        let manager = ManagerInstance(id: "test-app-bundles", kind: .appBundle,
                                      executablePath: "", executableFingerprint: "native-app-trash",
                                      scope: ManagerScope(id: "test-folder", displayName: "Test Applications", canonicalRoot: appRoot.path),
                                      removalSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: manager.scope.id,
                                      nativeID: bundleIdentifier, canonicalLocation: appURL.path)
        let installation = Installation(identity: identity, kind: .appBundle, displayName: "OrdinaryApp", version: "1",
                                         canonicalLocation: appURL.path, bundleIdentifier: bundleIdentifier,
                                         ownership: .verified, isProtected: protected,
                                         protectionReason: protected ? "This protected app cannot be moved to Trash." : nil,
                                         removalSupported: true, isStale: false)
        let snapshot = InventorySnapshot(installations: [installation], managers: [manager],
                                         coverage: [CoverageSnapshot(id: manager.id, sourceName: "Applications", scopeID: manager.scope.id,
                                                                     state: .complete, itemCount: 1)])
        let store = InMemoryInstallationStore()
        await store.saveSnapshot(snapshot)
        let runner = FakeRunner()
        let trashExecutor = FakeTrashExecutor()
        let adapter = FakeAdapter(manager: manager, installation: installation, guidanceOnly: false, trashTarget: target)
        let engine = AppHarborCoreEngine(adapters: [adapter], runner: runner, appTrashExecutor: trashExecutor, store: store)
        _ = await engine.refresh()
        let defaults = UserDefaults(suiteName: "AppHarbor-NativeTrashTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: "AppHarbor.mcpBridgeEnabled")
        defaults.set(true, forKey: "AppHarbor.mcpActionRequestsEnabled")
        let socketURL = FileManager.default.temporaryDirectory.appendingPathComponent("ah-\(UUID().uuidString).sock")
        let model = LibraryModel(engine: engine, store: store, preferences: defaults,
                                 mcpServer: MCPBridgeServer(socketURL: socketURL), mcpReviewTTL: 300)
        try await waitForSnapshot(model)
        return Fixture(model: model, installation: installation, runner: runner, trashExecutor: trashExecutor, appRoot: appRoot)
    }

    private func prepareRemoval(in fixture: Fixture) async throws -> ActionPlan {
        let request = removalRequest(requestID: UUID().uuidString.lowercased(), installation: fixture.installation)
        let response = await fixture.model.handleMCPRequest(request)
        XCTAssertEqual(try json(response)["status"] as? String, "preparing")
        try await waitForReview(fixture.model)
        guard case let .ready(plan)? = fixture.model.planDecision else {
            XCTFail("Expected an AppHarbor-ready review plan")
            throw TestError.noReviewPlan
        }
        return plan
    }

    private func waitForSnapshot(_ model: LibraryModel) async throws {
        for _ in 0..<100 {
            if !model.installations.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.timedOut
    }

    private func waitForReview(_ model: LibraryModel) async throws {
        for _ in 0..<100 {
            if case .ready(_) = model.planDecision { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.timedOut
    }

    private func waitForDecision(_ model: LibraryModel) async throws {
        for _ in 0..<100 {
            if !model.isPreparingPlan, model.planDecision != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.timedOut
    }

    private func removalRequest(requestID: String, installation: Installation) -> MCPBridgeRequest {
        MCPBridgeRequest(action: .requestRemoval,
                         parameters: ["request_id": requestID,
                                      "installation_id": MCPInventoryPresenter.identifier(for: installation.identity)])
    }

    private func json(_ response: MCPBridgeResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.json.utf8)) as? [String: Any])
    }

    private enum TestError: Error { case noReviewPlan, timedOut }
}

private actor FakeRunner: ProcessRunning {
    private(set) var runCount = 0
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        runCount += 1
        return ProcessResult(standardOutput: "", standardError: "", exitCode: 0)
    }
}

private final class FakeTrashExecutor: NativeAppTrashExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
    func trash(_ target: AppBundleTrashTarget) throws -> NativeAppTrashResult {
        lock.lock(); calls += 1; lock.unlock()
        return NativeAppTrashResult(originalPathIsAbsent: true, trashedPath: "/test/Trash/OrdinaryApp.app", hasExpectedIdentity: true)
    }
}

private struct FakeAdapter: PackageManagerAdapter {
    let manager: ManagerInstance
    let installation: Installation
    let guidanceOnly: Bool
    var trashTarget: AppBundleTrashTarget? = nil
    var kind: ManagerKind { manager.kind }

    func detect(using runner: any ProcessRunning) async -> DetectionResult {
        DetectionResult(presence: .present, instances: [manager])
    }

    func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        AdapterInventoryResult(installations: [installation],
                               coverage: CoverageSnapshot(id: manager.id, sourceName: "Homebrew", scopeID: manager.scope.id,
                                                          state: .complete, itemCount: 1))
    }

    func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        if let trashTarget {
            return .ready(ActionPlan(installationID: self.installation.identity, operation: operation,
                                     managerInstanceID: manager.id, trashTarget: trashTarget,
                                     knownEffects: ["Moves only the app bundle to Finder Trash."],
                                     expectedResult: "The app is in Trash and absent from its original location."))
        }
        if guidanceOnly {
            return .guidance(RemovalGuidance(title: "Manual source review", steps: ["Use the source directly."], isVerified: false),
                             reason: "This test item is guidance only.")
        }
        return .ready(ActionPlan(installationID: self.installation.identity, operation: operation, managerInstanceID: manager.id,
                                 command: ProcessCommand(executablePath: manager.executablePath, arguments: ["uninstall", "--cask", "dockside"]),
                                 executableFingerprint: manager.executableFingerprint, targetFingerprint: "target-fingerprint",
                                 previewCommand: "brew uninstall --cask dockside", expectedResult: "The source no longer lists Dockside."))
    }

    func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        if case let .appBundleTrash(target) = plan.execution {
            return .valid(currentTargetFingerprint: target.metadataFingerprint, currentExecutableFingerprint: "native-app-trash")
        }
        return .valid(currentTargetFingerprint: "target-fingerprint", currentExecutableFingerprint: manager.executableFingerprint)
    }

    func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult {
        .verifiedRemoved
    }
}
