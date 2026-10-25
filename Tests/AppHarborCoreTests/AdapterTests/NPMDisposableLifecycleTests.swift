import XCTest
@testable import AppHarborCore

final class NPMDisposableLifecycleTests: XCTestCase {
    func testDisposableLocalPackageLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["APPHARBOR_RUN_DISPOSABLE_NPM_TEST"] == "1" else {
            throw XCTSkip("Set APPHARBOR_RUN_DISPOSABLE_NPM_TEST=1 to run the offline temporary-prefix lifecycle test.")
        }
        let npm = "/opt/homebrew/bin/npm", node = "/opt/homebrew/bin/node"
        guard AdapterSupport.executableExists(npm), AdapterSupport.executableExists(node) else { throw XCTSkip("Known Homebrew npm and Node paths are not available.") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-npm-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let package = base.appendingPathComponent("package", isDirectory: true)
        let prefix = base.appendingPathComponent("prefix", isDirectory: true).path
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let packageName = "appharbor-disposable-fixture"
        let manifest: [String: Any] = ["name": packageName, "version": "1.0.0", "description": "Disposable AppHarbor adapter fixture"]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: package.appendingPathComponent("package.json"))

        let runner = FoundationProcessRunner()
        let environment = AdapterSupport.baseEnvironment(executables: [npm, node])
        let install = try await runner.run(ProcessCommand(executablePath: npm, arguments: ["install", "--global", "--prefix", prefix, "--offline", "--ignore-scripts", "--no-audit", "--no-fund", package.path], environment: environment, workingDirectory: base.path, timeout: 90))
        XCTAssertEqual(install.exitCode, 0, "Temporary offline fixture install failed: \(install.standardError)")
        XCTAssertFalse(install.didTimeOut)

        let managerID = "npm|\(npm)|\(node)|\(prefix)"
        let scope = ManagerScope(id: AdapterSupport.canonicalPath(prefix), displayName: "Disposable npm scope", canonicalRoot: prefix, isExplicitlySelected: true)
        let root = URL(fileURLWithPath: prefix).appendingPathComponent("lib/node_modules").path
        let manager = ManagerInstance(id: managerID, kind: .npm, executablePath: npm, executableFingerprint: AdapterSupport.fingerprint([AdapterSupport.executableFingerprint(npm), AdapterSupport.executableFingerprint(node)]), scope: scope, evidence: [ManagerEvidence(label: "Global package root", value: root)], removalSupported: true, updateSupported: true)
        let adapter = NPMAdapter(explicitExecutables: [npm], explicitNodeExecutables: [node])
        let inventory = await adapter.inventory(instance: manager, using: runner)
        XCTAssertEqual(inventory.coverage.state, .complete, inventory.coverage.warning ?? "")
        let installation = try XCTUnwrap(inventory.installations.first(where: { $0.identity.nativeID == packageName }))
        XCTAssertEqual(inventory.installations.count, 1)
        guard case let .ready(plan) = await adapter.prepare(operation: .remove, installation: installation, using: runner) else { return XCTFail("Expected direct removal for the disposable local package") }
        guard case .valid = await adapter.revalidate(plan: plan, installation: installation, using: runner) else { return XCTFail("Disposable package failed fresh preflight") }
        XCTAssertTrue(plan.command!.arguments.contains("--ignore-scripts"))
        let removal = try await runner.run(plan.command!)
        XCTAssertEqual(removal.exitCode, 0, "Temporary fixture removal failed: \(removal.standardError)")
        let verification = await adapter.verify(plan: plan, installation: installation, using: runner)
        if verification != .verifiedRemoved {
            let diagnostic = try await runner.run(ProcessCommand(executablePath: npm, arguments: ["ls", "--global", "--depth=0", "--json", "--long", "--prefix", prefix], environment: AdapterSupport.baseEnvironment(executables: [npm, node])))
            let object = AdapterSupport.parsedJSON(diagnostic.standardOutput) as? [String: Any] ?? [:]
            print("ADAPTER_NPM_VERIFY_DIAG exit=\(diagnostic.exitCode) truncated=\(diagnostic.outputWasTruncated) topKeys=\(object.keys.sorted()) dependenciesType=\(String(describing: type(of: object["dependencies"] as Any))) parser=\(NPMParser.parseGlobalList(diagnostic.standardOutput, root: root) != nil)")
        }
        XCTAssertEqual(verification, .verifiedRemoved)
        if verification == .verifiedRemoved { print("ADAPTER_NPM_DISPOSABLE_LIFECYCLE install=success inventory=1 preflight=valid removal=success verification=verifiedRemoved") }
    }
}
