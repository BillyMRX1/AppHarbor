import XCTest
@testable import AppHarborCore

final class ManagerAdapterParserTests: XCTestCase {
    func testHomebrewKeepsFormulaAndCaskVersionsAndRejectsMalformedRows() throws {
        let json = #"{"formulae":[{"name":"demo","full_name":"homebrew/core/demo","tap":"homebrew/core","linked_keg":"2.1.0","installed":[{"version":"2.0.0"},{"version":"2.1.0"}]}],"casks":[{"token":"demo-app","installed":"3.2.1","artifacts":[{"app":["/Applications/Demo.app"]}]}]}"#
        let rows = try XCTUnwrap(HomebrewParser.parseInstalled(json))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.kind == .formula })?.version, "2.1.0")
        XCTAssertEqual(rows.first(where: { $0.kind == .cask })?.bundlePaths, ["/Applications/Demo.app"])
        XCTAssertNil(HomebrewParser.parseInstalled(#"{"formulae":[{"name":"broken","installed":[]}],"casks":[]}"#))
        XCTAssertNil(HomebrewParser.parseInstalled("not json"))
    }

    func testHomebrewOutdatedRequiresCompleteRecognizedSchema() throws {
        XCTAssertNil(HomebrewParser.parseOutdated("{}"))
        XCTAssertNil(HomebrewParser.parseOutdated(#"{"formulae":[]}"#))
        XCTAssertEqual(try XCTUnwrap(HomebrewParser.parseOutdated(#"{"version":2,"formulae":[],"casks":[]}"#)), [])
        XCTAssertEqual(try XCTUnwrap(HomebrewParser.parseOutdated(#"{"formulae":[{"name":"demo"}],"casks":[]}"#)), ["demo"])
        let documentedCandidate = #"{"formulae":[{"name":"homebrew/core/demo","installed_versions":["1.0"],"current_version":"1.1","pinned":false}],"casks":[]}"#
        XCTAssertEqual(HomebrewParser.availableVersion(documentedCandidate, package: "homebrew/core/demo"), "1.1")
        XCTAssertTrue(HomebrewParser.isValidPackageName("homebrew/core/demo"))
        XCTAssertFalse(HomebrewParser.isValidPackageName("../demo"))
        XCTAssertFalse(HomebrewParser.isValidPackageName("tap/path/demo/extra"))
        XCTAssertNil(HomebrewParser.parseOutdated(#"{"formulae":[{"name":"../demo"}],"casks":[]}"#))
        XCTAssertEqual(HomebrewParser.parseCaskListOutput("Firefox.app\n/Applications/Firefox.app\n/Applications/Other.app/Contents/Info.plist\n"), ["/Applications/Firefox.app"])
    }

    func testDuplicateNamesRemainDistinctAcrossNpmPrefixes() throws {
        let json = #"{"dependencies":{"shared":{"version":"1.2.0"}}}"#
        let one = try XCTUnwrap(NPMParser.parseGlobalList(json, root: "/one/lib/node_modules"))
        let two = try XCTUnwrap(NPMParser.parseGlobalList(json, root: "/two/lib/node_modules"))
        XCTAssertEqual(one[0].name, two[0].name)
        XCTAssertNotEqual(one[0].path, two[0].path)
        XCTAssertNil(NPMParser.parseGlobalList(#"{"dependencies":{"broken":{"missing":true}}}"#, root: "/one/lib/node_modules"))
        XCTAssertEqual(NPMParser.parseGlobalList(#"{"name":"node_modules","path":"/tmp/prefix/lib/node_modules","extraneous":false}"#, root: "/tmp/prefix/lib/node_modules"), [])
        XCTAssertNil(NPMParser.parseGlobalList(#"{"name":"node_modules","path":"/tmp/prefix/lib/node_modules","extraneous":false,"problems":["missing"]}"#, root: "/tmp/prefix/lib/node_modules"))
        XCTAssertTrue(NPMParser.isValidPackageName("@scope/pkg"))
        XCTAssertFalse(NPMParser.isValidPackageName("user/repo"))
        XCTAssertFalse(NPMParser.isValidPackageName("/tmp/pkg"))
        XCTAssertNil(NPMParser.parseGlobalList(#"{"dependencies":{"user/repo":{"version":"1.0.0"}}}"#, root: "/tmp/prefix/lib/node_modules"))
    }

    func testNpmSourceClassificationNeverPersistsCustomRegistryURL() throws {
        let publicJSON = #"{"dependencies":{"public":{"version":"1.0.0","resolved":"https://registry.npmjs.org/public/-/public-1.0.0.tgz"}}}"#
        let privateJSON = #"{"dependencies":{"private":{"version":"1.0.0","resolved":"https://user:secret@packages.example.invalid/private.tgz"}}}"#
        XCTAssertEqual(try XCTUnwrap(NPMParser.parseGlobalList(publicJSON, root: "/p/lib/node_modules")).first?.source, .publicRegistry)
        XCTAssertEqual(try XCTUnwrap(NPMParser.parseGlobalList(privateJSON, root: "/p/lib/node_modules")).first?.source, .customRegistry)
    }

    func testPipxNestedMetadataAndInjectedPackagesAreParsedWithoutSourceSecrets() throws {
        let json = #"{"venvs":{"tool":{"metadata":{"main_package":{"package":"tool","package_version":"1.4.2","package_or_url":"tool","pip_args":[]},"injected_packages":{"plugin":{"package":"plugin","package_version":"2.0"}}}}}}"#
        let rows = try XCTUnwrap(PipxParser.parseList(json))
        XCTAssertEqual(rows.first?.package, "tool")
        XCTAssertEqual(rows.first?.injected, ["plugin"])
        XCTAssertFalse(try XCTUnwrap(rows.first).hasCustomSource)
        XCTAssertNil(PipxParser.parseList(#"{"venvs":{"broken":{"metadata":{"injected_packages":{"x":"bad"}}}}}"#))
    }

    func testPipxEnvironmentContainingManagerExecutableIsGuidanceOnly() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-pipx-self-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("pipx-home").path
        let environment = home + "/venvs/pipx"
        let executable = environment + "/bin/pipx"
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: executable).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let managerID = "pipx|\(executable)|\(home)"
        let identity = InstallationID(managerID: managerID, scopeID: home, nativeID: "pipx", canonicalLocation: environment)
        let installation = Installation(identity: identity, kind: .pipxEnvironment, displayName: "pipx", version: "1.0.0", canonicalLocation: environment, ownership: .verified, removalSupported: true)
        let result = await PipxAdapter().prepare(operation: .remove, installation: installation, using: StaticRunner(output: "{}"))
        guard case .guidance(_, let reason) = result else { return XCTFail("A pipx environment containing its only manager must be guidance-only") }
        XCTAssertTrue(reason.contains("selected pipx executable is inside this environment"))
    }

    func testCargoPreflightInvalidatesWhenFreshPackageNowOwnsManagerBinary() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-cargo-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root").path
        let executable = root + "/bin/cargo"
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: executable).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let managerID = "cargo|\(executable)|\(root)"
        let identity = InstallationID(managerID: managerID, scopeID: root, nativeID: "tool", canonicalLocation: root + "/bin")
        let installation = Installation(identity: identity, kind: .cargoPackage, displayName: "tool", version: "1.0.0", canonicalLocation: identity.canonicalLocation, ownership: .verified, evidence: [ManagerEvidence(label: "Installed binaries", value: "tool-bin")], removalSupported: true)
        guard case let .ready(plan) = await CargoAdapter(explicitRoots: [root]).prepare(operation: .remove, installation: installation, using: StaticRunner(output: "")) else { return XCTFail("Expected ordinary Cargo removal plan before fresh ownership evidence") }
        let current = await CargoAdapter(explicitRoots: [root]).revalidate(plan: plan, installation: installation, using: CargoListRunner(output: "Installed packages:\ntool v1.0.0:\n    cargo\n"))
        guard case .invalidated = current else { return XCTFail("Cargo preflight must reject a package that now owns its manager binary") }
    }

    func testManagerVerifiersRejectChangedExecutableFingerprintBeforeAbsenceClaim() async throws {
        let runner = StaticRunner(output: "{}")
        let npmID = InstallationID(managerID: "npm|/usr/bin/true|/usr/bin/true|/tmp/npm", scopeID: "/tmp/npm", nativeID: "pkg", canonicalLocation: "/tmp/npm/lib/node_modules/pkg")
        let npm = Installation(identity: npmID, kind: .npmPackage, displayName: "pkg", canonicalLocation: npmID.canonicalLocation, ownership: .verified)
        let pipxID = InstallationID(managerID: "pipx|/usr/bin/true|/tmp/pipx", scopeID: "/tmp/pipx", nativeID: "tool", canonicalLocation: "/tmp/pipx/venvs/tool")
        let pipx = Installation(identity: pipxID, kind: .pipxEnvironment, displayName: "tool", canonicalLocation: pipxID.canonicalLocation, ownership: .verified)
        let cargoID = InstallationID(managerID: "cargo|/usr/bin/true|/tmp/cargo", scopeID: "/tmp/cargo", nativeID: "tool", canonicalLocation: "/tmp/cargo/bin")
        let cargo = Installation(identity: cargoID, kind: .cargoPackage, displayName: "tool", canonicalLocation: cargoID.canonicalLocation, ownership: .verified)
        func wrongFingerprintPlan(_ installation: Installation) -> ActionPlan {
            ActionPlan(installationID: installation.identity, operation: .remove, managerInstanceID: installation.identity.managerID, command: ProcessCommand(executablePath: "/usr/bin/true", arguments: []), executableFingerprint: "changed-manager", targetFingerprint: "fixture", previewCommand: "fixture", expectedResult: "removed")
        }
        let npmResult = await NPMAdapter().verify(plan: wrongFingerprintPlan(npm), installation: npm, using: runner)
        let pipxResult = await PipxAdapter().verify(plan: wrongFingerprintPlan(pipx), installation: pipx, using: runner)
        let cargoResult = await CargoAdapter().verify(plan: wrongFingerprintPlan(cargo), installation: cargo, using: runner)
        XCTAssertEqual(npmResult, .incomplete)
        XCTAssertEqual(pipxResult, .incomplete)
        XCTAssertEqual(cargoResult, .incomplete)
    }

    func testCargoEmptyAndMalformedOutputAreDifferent() throws {
        XCTAssertEqual(try XCTUnwrap(CargoParser.parseInstallList("Installed packages:\n")), [])
        XCTAssertNil(CargoParser.parseInstallList("Installed packages:\npackage v1.0.0:\nnot indented"))
        let rows = try XCTUnwrap(CargoParser.parseInstallList("Installed packages:\npackage v1.0.0:\n    package-bin"))
        XCTAssertEqual(rows.first?.binaries, ["package-bin"])
    }

    func testAppBundleScanFindsNestedAppsProtectsAppleAndRejectsEscapingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-apps-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-outside-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try makeBundle(root.appendingPathComponent("Utilities/Nested.app", isDirectory: true), id: "org.example.nested", display: "Nested")
        try makeBundle(root.appendingPathComponent("Apple.app", isDirectory: true), id: "com.apple.fixture", display: "Apple")
        try makeBundle(outside, id: "org.example.outside", display: "Outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escaping.app"), withDestinationURL: outside)
        let result = AppBundleInventory.scan(roots: [root.path])
        XCTAssertEqual(Set(result.installations.compactMap(\.bundleIdentifier)), ["org.example.nested", "com.apple.fixture", "org.example.outside"])
        XCTAssertTrue(result.installations.first(where: { $0.bundleIdentifier == "com.apple.fixture" })?.isProtected == true)
        XCTAssertTrue(result.installations.first(where: { $0.bundleIdentifier == "org.example.outside" })?.isProtected == true)
    }

    func testCaskAppLinksRequireExactReportedPath() {
        let caskID = InstallationID(managerID: "brew", scopeID: "/opt/homebrew", nativeID: "demo", canonicalLocation: "/opt/homebrew/Caskroom/demo")
        let appID = InstallationID(managerID: "apps", scopeID: "/Applications", nativeID: "org.example.demo", canonicalLocation: "/Applications/Demo.app")
        let cask = Installation(identity: caskID, kind: .cask, displayName: "Demo", canonicalLocation: caskID.canonicalLocation, ownership: .verified, evidence: [ManagerEvidence(label: "Bundle path", value: "/Applications/Demo.app")])
        let app = Installation(identity: appID, kind: .appBundle, displayName: "Another display name", canonicalLocation: appID.canonicalLocation, ownership: .unknown)
        XCTAssertTrue(AppBundleInventory.isVerifiedCaskLink(cask: cask, appBundle: app))
        var other = app; other.canonicalLocation = "/Applications/Other.app"
        XCTAssertFalse(AppBundleInventory.isVerifiedCaskLink(cask: cask, appBundle: other))
    }

    func testRelativeCaskArtifactUsesOnlyManagerListedAbsoluteAppPath() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-cask-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let prefix = base.appendingPathComponent("prefix").path
        let app = base.appendingPathComponent("Applications/Firefox.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let brew = base.appendingPathComponent("brew").path
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: brew))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew)
        let managerID = "brew|\(brew)|\(prefix)"
        let manager = ManagerInstance(id: managerID, kind: .homebrew, executablePath: brew, executableFingerprint: AdapterSupport.executableFingerprint(brew), scope: ManagerScope(id: prefix, displayName: prefix, canonicalRoot: prefix))
        let info = #"{"formulae":[],"casks":[{"token":"firefox","tap":"homebrew/cask","installed":"1.0","artifacts":[{"app":"Firefox.app"}]}]}"#
        let result = await HomebrewAdapter().inventory(instance: manager, using: HomebrewCaskRunner(prefix: prefix, info: info, appPath: app.path))
        let cask = try XCTUnwrap(result.installations.first)
        XCTAssertEqual(result.coverage.state, .complete)
        XCTAssertEqual(cask.evidence.first(where: { $0.label == "Bundle path" })?.value, AdapterSupport.canonicalPath(app.path))
    }

    func testNpmRemovePlanBindsExplicitPrefixAndFreshPreflightCatchesChangedVersion() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-npm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let npm = base.appendingPathComponent("npm").path, node = base.appendingPathComponent("node").path
        for path in [npm, node] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let prefix = base.appendingPathComponent("scope", isDirectory: true).path
        let managerID = "npm|\(npm)|\(node)|\(prefix)"
        let location = prefix + "/lib/node_modules/shared"
        let identity = InstallationID(managerID: managerID, scopeID: prefix, nativeID: "shared", canonicalLocation: location)
        let installation = Installation(identity: identity, kind: .npmPackage, displayName: "shared", version: "1.2.0", canonicalLocation: location, ownership: .verified, removalSupported: true)
        let adapter = NPMAdapter()
        let runner = StaticRunner(output: #"{"dependencies":{"shared":{"version":"1.3.0"}}}"#)
        guard case let .ready(plan) = await adapter.prepare(operation: .remove, installation: installation, using: runner) else { return XCTFail("Expected a direct npm removal plan") }
        XCTAssertTrue(plan.command.arguments.contains("--prefix"))
        XCTAssertEqual(plan.command.arguments[plan.command.arguments.firstIndex(of: "--prefix")! + 1], prefix)
        XCTAssertTrue(plan.previewCommand.contains("cd \(prefix) && env "))
        XCTAssertTrue(plan.previewCommand.contains("PATH="))
        if case .invalidated = await adapter.revalidate(plan: plan, installation: installation, using: runner) { } else { XCTFail("Fresh inventory with a changed version must invalidate the plan") }
    }

    func testNpmSelfRemovalIsGuidanceOnly() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-npm-self-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let npm = base.appendingPathComponent("npm").path, node = base.appendingPathComponent("node").path
        for path in [npm, node] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let prefix = base.appendingPathComponent("scope", isDirectory: true).path
        let managerID = "npm|\(npm)|\(node)|\(prefix)"
        let location = prefix + "/lib/node_modules/npm"
        let identity = InstallationID(managerID: managerID, scopeID: prefix, nativeID: "npm", canonicalLocation: location)
        let installation = Installation(identity: identity, kind: .npmPackage, displayName: "npm", version: "11.0.0", canonicalLocation: location, ownership: .verified, removalSupported: true, updateSupported: true)
        let decision = await NPMAdapter().prepare(operation: .remove, installation: installation, using: StaticRunner(output: "{}"))
        guard case .guidance(_, let reason) = decision else { return XCTFail("Removing npm itself must not create a direct action plan") }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("owns the selected npm or Node executable"))
    }

    func testNpmUpdatePlanPinsReviewedCandidateAndPreflightRechecksIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-npm-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let npm = base.appendingPathComponent("npm").path, node = base.appendingPathComponent("node").path
        for path in [npm, node] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let prefix = base.appendingPathComponent("scope", isDirectory: true).path
        let managerID = "npm|\(npm)|\(node)|\(prefix)"
        let root = prefix + "/lib/node_modules"
        let location = root + "/pkg"
        let identity = InstallationID(managerID: managerID, scopeID: prefix, nativeID: "pkg", canonicalLocation: location)
        let installation = Installation(identity: identity, kind: .npmPackage, displayName: "pkg", version: "1.0.0", canonicalLocation: location, ownership: .verified, evidence: [ManagerEvidence(label: "Update source", value: "public npm registry")], removalSupported: true, updateSupported: true)
        let reviewed = NPMUpdateRunner(candidate: "1.1.0")
        guard case let .ready(plan) = await NPMAdapter().prepare(operation: .update, installation: installation, using: reviewed) else { return XCTFail("Expected validated public-registry exact-version plan") }
        XCTAssertTrue(plan.command.arguments.contains("install"))
        XCTAssertTrue(plan.command.arguments.contains("--ignore-scripts"))
        XCTAssertTrue(plan.command.arguments.contains("--registry"))
        XCTAssertEqual(plan.command.arguments.last, "pkg@1.1.0")
        XCTAssertEqual(plan.approvedUpdateVersion, "1.1.0")
        XCTAssertEqual(plan.approvedSourcePolicy, "https://registry.npmjs.org")
        let changed = NPMUpdateRunner(candidate: "1.2.0")
        guard case .invalidated = await NPMAdapter().revalidate(plan: plan, installation: installation, using: changed) else { return XCTFail("A changed candidate must invalidate the reviewed update plan") }
    }

    func testHomebrewVerifyWillNotClaimRemovalWhenPrefixChanges() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-brew-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let brew = base.appendingPathComponent("brew").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: brew))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew)
        let prefix = base.appendingPathComponent("expected-prefix").path
        let managerID = "brew|\(brew)|\(prefix)"
        let location = prefix + "/Cellar/demo/1.0.0"
        let identity = InstallationID(managerID: managerID, scopeID: prefix, nativeID: "demo", canonicalLocation: location)
        let installation = Installation(identity: identity, kind: .formula, displayName: "demo", version: "1.0.0", canonicalLocation: location, ownership: .verified, removalSupported: true)
        let fingerprint = AdapterSupport.executableFingerprint(brew)
        let plan = ActionPlan(installationID: identity, operation: .remove, managerInstanceID: managerID, command: ProcessCommand(executablePath: brew, arguments: []), executableFingerprint: fingerprint, targetFingerprint: "fixture", previewCommand: "brew uninstall demo", expectedResult: "absent")
        let result = await HomebrewAdapter().verify(plan: plan, installation: installation, using: PrefixChangingRunner())
        XCTAssertEqual(result, .incomplete)
    }

    func testOptInReadOnlyHostHomebrewInventoryReportsAggregateCaskLinks() async throws {
        guard ProcessInfo.processInfo.environment["APPHARBOR_RUN_BREW_READONLY_SMOKE"] == "1" else {
            throw XCTSkip("Set APPHARBOR_RUN_BREW_READONLY_SMOKE=1 to scan installed Homebrew packages read-only.")
        }
        let adapter = HomebrewAdapter()
        let detection = await adapter.detect(using: FoundationProcessRunner())
        let instances = detection.instances.filter { $0.kind == .homebrew }
        guard !instances.isEmpty else { throw XCTSkip("No trusted Homebrew executable was detected at known paths.") }
        var formulas = 0, casks = 0, linkedBundles = 0, partialScopes = 0
        for manager in instances {
            let inventory = await adapter.inventory(instance: manager, using: FoundationProcessRunner())
            XCTAssertNotEqual(inventory.coverage.state, .failed, inventory.coverage.warning ?? "")
            formulas += inventory.installations.filter { $0.kind == .formula }.count
            casks += inventory.installations.filter { $0.kind == .cask }.count
            linkedBundles += inventory.installations.filter { $0.kind == .cask }.reduce(0) { count, item in count + item.evidence.filter { $0.label == "Bundle path" }.count }
            if inventory.coverage.state == .partial { partialScopes += 1 }
        }
        print("ADAPTER_BREW_READONLY_SMOKE prefixes=\(instances.count) formulas=\(formulas) casks=\(casks) verifiedBundlePaths=\(linkedBundles) partialScopes=\(partialScopes)")
    }

    func testHomebrewVerificationUsesFreshNativeIDAcrossVersionedLocations() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-brew-versioned-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let brew = base.appendingPathComponent("brew").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: brew))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew)
        let prefix = base.appendingPathComponent("prefix").path
        let managerID = "brew|\(brew)|\(prefix)"
        let oldLocation = prefix + "/Cellar/demo/1.0.0"
        let identity = InstallationID(managerID: managerID, scopeID: prefix, nativeID: "homebrew/core/demo", canonicalLocation: oldLocation)
        let installation = Installation(identity: identity, kind: .formula, displayName: "demo", version: "1.0.0", canonicalLocation: oldLocation, ownership: .verified, removalSupported: true, updateSupported: true)
        let fingerprint = AdapterSupport.executableFingerprint(brew)
        let info = #"{"formulae":[{"name":"demo","full_name":"homebrew/core/demo","tap":"homebrew/core","linked_keg":"2.0.0","installed":[{"version":"2.0.0"}]}],"casks":[]}"#
        let runner = HomebrewInventoryRunner(prefix: prefix, info: info)
        let removal = ActionPlan(installationID: identity, operation: .remove, managerInstanceID: managerID, command: ProcessCommand(executablePath: brew, arguments: []), executableFingerprint: fingerprint, targetFingerprint: "fixture", previewCommand: "brew uninstall demo", expectedResult: "absent")
        let removalVerification = await HomebrewAdapter().verify(plan: removal, installation: installation, using: runner)
        XCTAssertEqual(removalVerification, .stillPresent)
        let update = ActionPlan(installationID: identity, operation: .update, managerInstanceID: managerID, command: ProcessCommand(executablePath: brew, arguments: []), executableFingerprint: fingerprint, targetFingerprint: "fixture", previewCommand: "brew upgrade demo", expectedResult: "updated", approvedUpdateVersion: "2.0.0", approvedSourcePolicy: "homebrew/core")
        let updateVerification = await HomebrewAdapter().verify(plan: update, installation: installation, using: runner)
        XCTAssertEqual(updateVerification, .verifiedUpdated)
        var wrongCandidate = update; wrongCandidate.approvedUpdateVersion = "3.0.0"
        let wrongCandidateVerification = await HomebrewAdapter().verify(plan: wrongCandidate, installation: installation, using: runner)
        XCTAssertEqual(wrongCandidateVerification, .incomplete)
    }

    private func makeBundle(_ url: URL, id: String, display: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleDisplayName": display, "CFBundleShortVersionString": "1.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

private struct StaticRunner: ProcessRunning {
    let output: String
    let status: Int32
    init(output: String, status: Int32 = 0) { self.output = output; self.status = status }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        ProcessResult(standardOutput: output, standardError: "", exitCode: status)
    }
}

private struct PrefixChangingRunner: ProcessRunning {
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        ProcessResult(standardOutput: command.arguments == ["--prefix"] ? "/wrong/prefix\n" : #"{"formulae":[],"casks":[]}"#, standardError: "", exitCode: 0)
    }
}

private struct HomebrewInventoryRunner: ProcessRunning {
    let prefix: String
    let info: String
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        ProcessResult(standardOutput: command.arguments == ["--prefix"] ? prefix : info, standardError: "", exitCode: 0)
    }
}

private struct HomebrewCaskRunner: ProcessRunning {
    let prefix: String
    let info: String
    let appPath: String
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        let output: String
        if command.arguments == ["--prefix"] { output = prefix }
        else if command.arguments.first == "info" { output = info }
        else if command.arguments == ["list", "--cask", "firefox"] { output = appPath + "\n" }
        else { output = "" }
        return ProcessResult(standardOutput: output, standardError: "", exitCode: 0)
    }
}

private struct CargoListRunner: ProcessRunning {
    let output: String
    func run(_ command: ProcessCommand) async throws -> ProcessResult { ProcessResult(standardOutput: output, standardError: "", exitCode: 0) }
}

private struct NPMUpdateRunner: ProcessRunning {
    let candidate: String
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        let output: String
        if command.arguments.first == "ls" {
            output = #"{"dependencies":{"pkg":{"version":"1.0.0","resolved":"https://registry.npmjs.org/pkg/-/pkg-1.0.0.tgz"}}}"#
        } else if command.arguments.first == "config" {
            output = "https://registry.npmjs.org/\n"
        } else if command.arguments.first == "outdated" {
            output = #"{"pkg":{"current":"1.0.0","wanted":""# + candidate + #""}}"#
        } else { output = "" }
        return ProcessResult(standardOutput: output, standardError: "", exitCode: command.arguments.first == "outdated" ? 1 : 0)
    }
}
