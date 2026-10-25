import XCTest
@testable import AppHarborCore

private struct TestTrashExecutor: NativeAppTrashExecuting {
    let counter: TrashCounter
    var failAfterMove = false
    func trash(_ target: AppBundleTrashTarget) throws -> NativeAppTrashResult {
        counter.calls += 1
        if failAfterMove {
            let destination = URL(fileURLWithPath: target.scopeRoot).deletingLastPathComponent().appendingPathComponent("SimulatedTrash", isDirectory: true).appendingPathComponent(URL(fileURLWithPath: target.appPath).lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: target.appPath), to: destination)
            throw NativeAppTrashError.trashVerificationFailed
        }
        return NativeAppTrashResult(originalPathIsAbsent: true, trashedPath: "/isolated/Trash/Example.app", hasExpectedIdentity: true)
    }
}

private final class TrashCounter: @unchecked Sendable {
    var calls = 0
}

private struct NativeAppFixtureAdapter: PackageManagerAdapter {
    let manager: ManagerInstance
    let installation: Installation
    let target: AppBundleTrashTarget
    var planLifetime: TimeInterval = 300
    var preflightDelay: Duration = .zero
    var kind: ManagerKind { .appBundle }

    func detect(using runner: any ProcessRunning) async -> DetectionResult { DetectionResult(presence: .present, instances: [manager]) }
    func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        AdapterInventoryResult(installations: [installation], coverage: CoverageSnapshot(id: manager.id, sourceName: "App Bundles", scopeID: manager.scope.id, state: .complete, itemCount: 1))
    }
    func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        .ready(ActionPlan(installationID: installation.identity, operation: operation, managerInstanceID: manager.id, trashTarget: target, expiresAt: .now.addingTimeInterval(planLifetime)))
    }
    func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        if preflightDelay != .zero { try? await Task.sleep(for: preflightDelay) }
        return .valid(currentTargetFingerprint: target.metadataFingerprint, currentExecutableFingerprint: "native-app-trash")
    }
    func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult { .verifiedRemoved }
}

final class NativeAppTrashTests: XCTestCase {
    func testConfirmedNativeRemovalUsesInjectedTrashExecutorAndDeclineDoesNot() async throws {
        let (root, target) = try makeSyntheticApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ManagerScope(id: root.appendingPathComponent("Applications", isDirectory: true).path, displayName: "Applications", canonicalRoot: root.appendingPathComponent("Applications", isDirectory: true).path)
        let manager = ManagerInstance(id: "native-app-bundles", kind: .appBundle, executablePath: "<native>", executableFingerprint: "native-app-trash", scope: scope, removalSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: scope.id, nativeID: target.bundleIdentifier, canonicalLocation: target.appPath)
        let installation = Installation(identity: identity, kind: .appBundle, displayName: "Example", version: "1.0", canonicalLocation: target.appPath, bundleIdentifier: target.bundleIdentifier, ownership: .verified, removalSupported: true)
        let adapter = NativeAppFixtureAdapter(manager: manager, installation: installation, target: target)
        let counter = TrashCounter()
        let engine = AppHarborCoreEngine(adapters: [adapter], appTrashExecutor: TestTrashExecutor(counter: counter), store: InMemoryInstallationStore())

        _ = await engine.refresh()
        guard case let .ready(plan) = await engine.prepare(operation: .remove, installationID: identity) else { return XCTFail("Expected a native Trash plan") }
        XCTAssertNil(plan.command)
        let declined = await engine.execute(planID: plan.id, confirmed: false)
        XCTAssertEqual(declined.state, .invalidated)
        XCTAssertEqual(counter.calls, 0)

        let completed = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.verification, .verifiedRemoved)
        XCTAssertEqual(counter.calls, 1)
    }

    func testNativeVerificationFailureCannotBeConvertedToSuccessByManagerInventory() async throws {
        let (root, target) = try makeSyntheticApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ManagerScope(id: URL(fileURLWithPath: target.scopeRoot).path, displayName: "Apps", canonicalRoot: target.scopeRoot)
        let manager = ManagerInstance(id: "native-app-bundles", kind: .appBundle, executablePath: "<native>", executableFingerprint: "native-app-trash", scope: scope, removalSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: scope.id, nativeID: target.bundleIdentifier, canonicalLocation: target.appPath)
        let installation = Installation(identity: identity, kind: .appBundle, displayName: "Example", canonicalLocation: target.appPath, bundleIdentifier: target.bundleIdentifier, ownership: .verified, removalSupported: true)
        let adapter = NativeAppFixtureAdapter(manager: manager, installation: installation, target: target)
        let counter = TrashCounter()
        let engine = AppHarborCoreEngine(adapters: [adapter], appTrashExecutor: TestTrashExecutor(counter: counter, failAfterMove: true), store: InMemoryInstallationStore())

        _ = await engine.refresh()
        guard case let .ready(plan) = await engine.prepare(operation: .remove, installationID: identity) else { return XCTFail("Expected a native Trash plan") }
        let completed = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(completed.state, .outcomeUnknown)
        XCTAssertEqual(completed.verification, .incomplete)
        XCTAssertFalse(completed.state == .succeeded)
        XCTAssertEqual(counter.calls, 1)
    }

    func testNativePlanExpiresDuringPreflightBeforeTrashExecutorRuns() async throws {
        let (root, target) = try makeSyntheticApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ManagerScope(id: target.scopeRoot, displayName: "Apps", canonicalRoot: target.scopeRoot)
        let manager = ManagerInstance(id: "native-app-bundles", kind: .appBundle, executablePath: "<native>", executableFingerprint: "native-app-trash", scope: scope, removalSupported: true)
        let identity = InstallationID(managerID: manager.id, scopeID: scope.id, nativeID: target.bundleIdentifier, canonicalLocation: target.appPath)
        let installation = Installation(identity: identity, kind: .appBundle, displayName: "Example", canonicalLocation: target.appPath, bundleIdentifier: target.bundleIdentifier, ownership: .verified, removalSupported: true)
        let adapter = NativeAppFixtureAdapter(manager: manager, installation: installation, target: target, planLifetime: 0.01, preflightDelay: .milliseconds(30))
        let counter = TrashCounter()
        let engine = AppHarborCoreEngine(adapters: [adapter], appTrashExecutor: TestTrashExecutor(counter: counter), store: InMemoryInstallationStore())
        _ = await engine.refresh()
        guard case let .ready(plan) = await engine.prepare(operation: .remove, installationID: identity) else { return XCTFail("Expected a native Trash plan") }
        let result = await engine.execute(planID: plan.id, confirmed: true)
        XCTAssertEqual(result.state, .invalidated)
        XCTAssertEqual(counter.calls, 0)
    }

    func testTargetFingerprintReadsFreshInfoPlistContent() throws {
        let (root, target) = try makeSyntheticApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let plistURL = URL(fileURLWithPath: target.appPath).appendingPathComponent("Contents/Info.plist")
        let previousModificationDate = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date)
        let original = try String(contentsOf: plistURL, encoding: .utf8)
        let modified = original.replacingOccurrences(of: "Example", with: "ExamplE")
        XCTAssertEqual(original.utf8.count, modified.utf8.count)
        try modified.write(to: plistURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: previousModificationDate], ofItemAtPath: plistURL.path)
        XCTAssertFalse(NativeAppTrash.fingerprintMatches(target))
    }

    func testCaptureRejectsSymlinkedAncestor() throws {
        let (root, target) = try makeSyntheticApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.deletingLastPathComponent().appendingPathComponent("AppHarborNativeTrashLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: target.scopeRoot))
        let linkedPath = link.appendingPathComponent("Example.app", isDirectory: true).path
        XCTAssertNil(AppBundleTrashTarget.capture(path: linkedPath, scopeRoot: link.path, bundleIdentifier: target.bundleIdentifier))
    }

    func testOptInFileManagerExecutorMovesOnlySyntheticBundleToTrashAndRestoresIt() throws {
        guard ProcessInfo.processInfo.environment["APPHARBOR_RUN_NATIVE_TRASH_TEST"] == "1" else {
            throw XCTSkip("Set APPHARBOR_RUN_NATIVE_TRASH_TEST=1 to run the isolated native Trash integration test.")
        }
        let (root, target) = try makeSyntheticApp()
        var returnedTrashURL: URL?
        defer {
            if let returnedTrashURL, FileManager.default.fileExists(atPath: returnedTrashURL.path), NativeAppTrash.matchesIdentity(path: returnedTrashURL.path, target: target) {
                try? FileManager.default.moveItem(at: returnedTrashURL, to: URL(fileURLWithPath: target.appPath, isDirectory: true))
            }
            try? FileManager.default.removeItem(at: root)
        }
        let result = try FileManagerAppTrashExecutor().trash(target)
        returnedTrashURL = URL(fileURLWithPath: result.trashedPath, isDirectory: true)
        XCTAssertTrue(result.isVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.trashedPath))
        XCTAssertTrue(NativeAppTrash.matchesIdentity(path: result.trashedPath, target: target))
    }

    private func makeSyntheticApp() throws -> (URL, AppBundleTrashTarget) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("AppHarborNativeTrash-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let app = apps.appendingPathComponent("Example.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.appharbor.synthetic", "CFBundleName": "Example", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            guard let target = AppBundleTrashTarget.capture(path: app.path, scopeRoot: apps.path) else { throw NSError(domain: "NativeAppTrashTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic app bundle was not accepted."]) }
            return (root, target)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
