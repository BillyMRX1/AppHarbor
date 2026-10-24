import Foundation

public enum HomebrewParser {
    public struct Package: Sendable, Equatable {
        public var name: String; public var version: String?; public var kind: InstallationKind; public var tap: String?; public var installedCount: Int; public var bundlePaths: [String] = []
    }

    public static func isValidPackageName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9@._+-]+$"#, options: .regularExpression) != nil }) else { return false }
        return parts.count == 1 || parts.count == 3
    }

    public static func parseInstalled(_ text: String) -> [Package]? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        var result: [Package] = []
        if let formulas = object["formulae"] as? [[String: Any]] {
            for item in formulas {
                guard let name = AdapterSupport.cleanDisplay(item["full_name"] as? String ?? item["name"] as? String),
                      isValidPackageName(name),
                      let installed = item["installed"] as? [[String: Any]], !installed.isEmpty else { return nil }
                let activeVersion = AdapterSupport.cleanDisplay(item["linked_keg"] as? String).flatMap { linked in installed.first(where: { ($0["version"] as? String) == linked })?["version"] as? String }
                let versions = installed.compactMap { AdapterSupport.cleanDisplay($0["version"] as? String) }
                guard versions.count == installed.count, let version = activeVersion ?? versions.sorted().last else { return nil }
                result.append(Package(name: name, version: version, kind: .formula, tap: AdapterSupport.cleanDisplay(item["tap"] as? String), installedCount: installed.count))
            }
        } else if object["formulae"] != nil { return nil }
        if let casks = object["casks"] as? [[String: Any]] {
            for item in casks {
                guard let name = AdapterSupport.cleanDisplay(item["token"] as? String),
                      isValidPackageName(name),
                      let version = AdapterSupport.cleanDisplay(item["installed"] as? String ?? (item["installed"] as? [String])?.first ?? item["version"] as? String) else { return nil }
                result.append(Package(name: name, version: version, kind: .cask, tap: AdapterSupport.cleanDisplay(item["tap"] as? String), installedCount: 1, bundlePaths: caskBundlePaths(item["artifacts"])))
            }
        } else if object["casks"] != nil { return nil }
        guard object["formulae"] != nil || object["casks"] != nil else { return nil }
        return result
    }

    public static func parseOutdated(_ text: String) -> Set<String>? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        // `brew outdated --json=v2` returns both arrays, including an empty array
        // for the package kind with no candidates. Missing either is not proof
        // that the selected package is current.
        guard let formulae = object["formulae"] as? [[String: Any]],
              let casks = object["casks"] as? [[String: Any]],
              object["version"] == nil || (object["version"] as? Int) == 2 else { return nil }
        var names = Set<String>()
        for rows in [formulae, casks] {
            for row in rows {
                guard let name = AdapterSupport.cleanDisplay(row["name"] as? String ?? row["token"] as? String ?? row["full_name"] as? String), isValidPackageName(name) else { return nil }
                names.insert(name)
            }
        }
        return names
    }

    public static func availableVersion(_ text: String, package name: String) -> String? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        for key in ["formulae", "casks"] {
            guard let rows = object[key] as? [[String: Any]] else { continue }
            if let row = rows.first(where: { ($0["name"] as? String ?? $0["token"] as? String ?? $0["full_name"] as? String) == name }) {
                return AdapterSupport.cleanDisplay(row["version"] as? String ?? row["latest_version"] as? String ?? row["available_version"] as? String ?? row["current_version"] as? String)
            }
        }
        return nil
    }

    public static func parseCaskListOutput(_ text: String) -> [String]? {
        guard !text.contains("\0") else { return nil }
        return Array(Set(text.components(separatedBy: .newlines).compactMap { line -> String? in
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), path.hasSuffix(".app"), !path.contains(".."), !path.contains("\\") else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        })).sorted()
    }

    private static func caskBundlePaths(_ raw: Any?) -> [String] {
        guard let artifacts = raw as? [Any] else { return [] }
        var paths = Set<String>()
        func visit(_ value: Any) {
            if let string = value as? String {
                guard string.hasPrefix("/"), string.hasSuffix(".app"), !string.contains("..") else { return }
                paths.insert(URL(fileURLWithPath: string).standardizedFileURL.path)
            } else if let array = value as? [Any] { array.forEach(visit) }
            else if let dictionary = value as? [String: Any] { dictionary.values.forEach(visit) }
        }
        artifacts.forEach(visit)
        return paths.sorted()
    }
}

public struct HomebrewAdapter: PackageManagerAdapter {
    public let kind: ManagerKind = .homebrew
    private let explicitExecutables: [String]
    public init(explicitExecutables: [String] = []) { self.explicitExecutables = explicitExecutables }

    private var candidates: [String] { AdapterSupport.candidateExecutables(named: "brew", known: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], explicit: explicitExecutables) }

    public func detect(using runner: any ProcessRunning) async -> DetectionResult {
        let paths = candidates
        guard !paths.isEmpty else { return DetectionResult(presence: .absent, explanation: "No Homebrew executable was found in known locations or configured paths.") }
        var instances: [ManagerInstance] = []; var hadFailure = false
        for path in paths {
            guard let ver = await AdapterSupport.run(runner, executable: path, arguments: ["--version"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(ver),
                  let version = AdapterSupport.cleanDisplay(ver.standardOutput.components(separatedBy: .newlines).first) else { hadFailure = true; continue }
            guard let prefixResult = await AdapterSupport.run(runner, executable: path, arguments: ["--prefix"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(prefixResult),
                  let prefixRaw = AdapterSupport.cleanDisplay(prefixResult.standardOutput) else { hadFailure = true; continue }
            let prefix = AdapterSupport.canonicalPath(prefixRaw)
            let id = "brew|\(path)|\(prefix)"
            let major = AdapterSupport.semverMajor(version)
            let supported = major.map { (4...7).contains($0) } ?? false
            instances.append(ManagerInstance(id: id, kind: kind, executablePath: path, executableFingerprint: AdapterSupport.executableFingerprint(path), version: version, architecture: prefix == "/opt/homebrew" ? "arm64-prefix" : (prefix == "/usr/local" ? "intel-prefix" : "custom-prefix"), scope: ManagerScope(id: prefix, displayName: prefix, canonicalRoot: prefix), presence: supported ? .present : .unsupportedVersion, evidence: [ManagerEvidence(label: "Executable", value: path), ManagerEvidence(label: "Prefix", value: prefix)], removalSupported: supported, updateSupported: supported))
        }
        if !instances.isEmpty { return DetectionResult(presence: instances.allSatisfy { $0.presence == .unsupportedVersion } ? .unsupportedVersion : .present, instances: instances, explanation: hadFailure ? "At least one Homebrew candidate was unavailable." : nil) }
        return DetectionResult(presence: hadFailure ? .unavailable : .unsupportedVersion, explanation: "Homebrew was found but its version or prefix could not be verified.")
    }

    public func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        let started = Date(); let root = instance.scope.canonicalRoot ?? ""
        guard let prefixResult = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["--prefix"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(prefixResult),
              AdapterSupport.cleanDisplay(prefixResult.standardOutput).map(AdapterSupport.canonicalPath) == root else {
            return AdapterInventoryResult(installations: [], coverage: CoverageSnapshot(id: instance.id, sourceName: "Homebrew", scopeID: instance.scope.id, state: .failed, startedAt: started, completedAt: .now, warning: "Homebrew's current prefix does not match this selected manager scope."))
        }
        guard let result = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["info", "--json=v2", "--installed"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(result),
              let packages = HomebrewParser.parseInstalled(result.standardOutput) else {
            return AdapterInventoryResult(installations: [], coverage: CoverageSnapshot(id: instance.id, sourceName: "Homebrew", scopeID: instance.scope.id, state: .failed, startedAt: started, completedAt: .now, warning: "Homebrew inventory failed or returned an unsupported response."))
        }
        var rows: [Installation] = []
        var incompleteBundleEvidence = false
        for package in packages {
            let cellarName = package.name.components(separatedBy: "/").last ?? package.name
            let path = AdapterSupport.canonicalPath(root + (package.kind == .formula ? "/Cellar/" : "/Caskroom/") + cellarName + "/" + (package.version ?? "unknown"))
            let id = InstallationID(managerID: instance.id, scopeID: instance.scope.id, nativeID: package.name, canonicalLocation: path)
            let name = package.name.components(separatedBy: "/").last ?? package.name
            var evidence = [ManagerEvidence(label: "Homebrew package", value: package.kind.rawValue)]
            evidence.append(ManagerEvidence(label: "Tap", value: package.tap ?? "Unknown"))
            var bundlePaths = package.bundlePaths
            if package.kind == .cask && bundlePaths.isEmpty {
                if let listing = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["list", "--cask", package.name], environment: Self.homebrewReadEnvironment),
                   AdapterSupport.commandSucceeded(listing), let listed = HomebrewParser.parseCaskListOutput(listing.standardOutput) {
                    bundlePaths = listed.filter { FileManager.default.fileExists(atPath: $0) }
                } else { incompleteBundleEvidence = true }
            }
            for bundlePath in bundlePaths {
                evidence.append(ManagerEvidence(label: "Bundle path", value: AdapterSupport.canonicalPath(bundlePath)))
            }
            if package.installedCount > 1 { evidence.append(ManagerEvidence(label: "Installed versions", value: String(package.installedCount))) }
            rows.append(Installation(identity: id, kind: package.kind, displayName: name, version: package.version, canonicalLocation: path, ownership: .verified, evidence: evidence, removalSupported: instance.removalSupported, updateSupported: instance.updateSupported))
        }
        return AdapterInventoryResult(installations: rows, coverage: CoverageSnapshot(id: instance.id, sourceName: "Homebrew", scopeID: instance.scope.id, state: incompleteBundleEvidence ? .partial : .complete, startedAt: started, completedAt: .now, itemCount: rows.count, warning: incompleteBundleEvidence ? "Some cask app paths could not be verified; package inventory is complete but app attribution may be incomplete." : nil))
    }

    public func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        guard let decoded = Self.decodeManagerIdentity(installation.identity.managerID), installation.identity.scopeID == decoded.prefix,
              installation.ownership == .verified, !installation.isProtected else { return .blocked(reason: "The Homebrew instance or scope does not match this installation." ) }
        guard operation == .remove ? installation.removalSupported : installation.updateSupported else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "This Homebrew version or package capability has not been validated for direct actions.") }
        let name = installation.identity.nativeID
        guard HomebrewParser.isValidPackageName(name) else { return .blocked(reason: "The package identifier is not valid for a direct Homebrew action.") }
        if operation == .remove && AdapterSupport.rootIsWithin(decoded.executable, root: installation.canonicalLocation) {
            return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "The selected Homebrew executable is inside this package's installation. Use another verified Homebrew runtime to remove it.")
        }
        if installation.evidence.contains(where: { $0.label == "Installed versions" }) { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Multiple formula versions are installed. Homebrew's uninstall command can affect all versions, so this item needs manager-specific review.") }
        guard let version = await AdapterSupport.run(runner, executable: decoded.executable, arguments: ["--version"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(version) else {
            return .blocked(reason: "The exact Homebrew executable could not be revalidated.")
        }
        return await makePlan(operation: operation, installation: installation, using: runner)
    }

    public func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        guard let parts = Self.decodeManagerIdentity(installation.identity.managerID), installation.identity.scopeID == parts.prefix,
              installation.kind == .formula || installation.kind == .cask else { return UpdateCheckResult(installationID: installation.identity, status: .unsupported, explanation: "This is not a Homebrew formula or cask.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .homebrew, executablePath: parts.executable, executableFingerprint: AdapterSupport.executableFingerprint(parts.executable), scope: ManagerScope(id: parts.prefix, displayName: parts.prefix, canonicalRoot: parts.prefix)), using: runner)
        guard fresh.coverage.state == .complete, fresh.installations.contains(where: { $0.identity.nativeID == installation.identity.nativeID && $0.kind == installation.kind && $0.version == installation.version }) else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "The selected package is no longer verifiable in this Homebrew prefix.") }
        let flag = installation.kind == .cask ? "--cask" : "--formula"
        guard let result = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["outdated", "--json=v2", flag, installation.identity.nativeID], environment: Self.homebrewUpdateCheckEnvironment),
              (result.exitCode == 0 || result.exitCode == 1), !result.didTimeOut, !result.wasCancelled, !result.outputWasTruncated,
              let outdated = HomebrewParser.parseOutdated(result.standardOutput) else { return UpdateCheckResult(installationID: installation.identity, status: .failed, currentVersion: installation.version, explanation: "Homebrew update status could not be parsed.") }
        let isOutdated = outdated.contains(installation.identity.nativeID)
        let candidate = HomebrewParser.availableVersion(result.standardOutput, package: installation.identity.nativeID)
        if isOutdated && candidate == nil { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "Homebrew marked this package outdated but did not provide a candidate version.") }
        return UpdateCheckResult(installationID: installation.identity, status: isOutdated ? .updateAvailable : .upToDate, currentVersion: installation.version, availableVersion: candidate, explanation: "Checked Homebrew's current local catalog in its owning prefix with auto-update disabled. An up-to-date result does not guarantee the remote catalog is current.")
    }

    private func makePlan(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        guard let parts = Self.decodeManagerIdentity(installation.identity.managerID) else { return .blocked(reason: "The Homebrew identity is malformed.") }
        let executable = parts.executable, prefix = parts.prefix
        guard AdapterSupport.canonicalPath(executable) == executable, AdapterSupport.executableFingerprint(executable).hasPrefix(executable + "|") else { return .blocked(reason: "The Homebrew executable changed.") }
        let kindFlag = installation.kind == .cask ? "--cask" : "--formula"
        var args: [String]
        var updateCandidate: String?
        if operation == .remove {
            args = ["uninstall", kindFlag, installation.identity.nativeID]
        } else {
            let pinned = await AdapterSupport.run(runner, executable: executable, arguments: ["list", "--pinned", kindFlag], environment: Self.homebrewReadEnvironment)
            guard let pinned, AdapterSupport.commandSucceeded(pinned) else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Pinned status could not be verified for this Homebrew installation.") }
            if pinned.standardOutput.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == installation.identity.nativeID }) {
                return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Homebrew reports this package as pinned. Review its pin and update policy manually.")
            }
            let sourceIsStandard = installation.evidence.first(where: { $0.label == "Tap" })?.value == (installation.kind == .cask ? "homebrew/cask" : "homebrew/core")
            guard sourceIsStandard else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "The package source is custom or unknown, so update behavior cannot be verified.") }
            guard let status = await AdapterSupport.run(runner, executable: executable, arguments: ["outdated", "--json=v2", kindFlag, installation.identity.nativeID], environment: Self.homebrewUpdateCheckEnvironment),
                  (status.exitCode == 0 || status.exitCode == 1), !status.didTimeOut, !status.wasCancelled, !status.outputWasTruncated,
                  let outdated = HomebrewParser.parseOutdated(status.standardOutput) else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Homebrew update status could not be verified.") }
            guard outdated.contains(installation.identity.nativeID) else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Homebrew reports no available update for this package.") }
            guard let candidate = HomebrewParser.availableVersion(status.standardOutput, package: installation.identity.nativeID) else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Homebrew did not provide an available version for this package.") }
            let oldMajor = AdapterSupport.semverMajor(installation.version), newMajor = AdapterSupport.semverMajor(candidate)
            if oldMajor == nil || newMajor == nil || (oldMajor != newMajor) { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "Homebrew candidate version \(candidate) could be a major-version change or uses an unrecognized version format. Review the version change manually.") }
            updateCandidate = candidate
            args = ["upgrade", kindFlag, installation.identity.nativeID]
        }
        let environment = operation == .update ? Self.homebrewMutationEnvironment : Self.homebrewReadEnvironment
        let command = ProcessCommand(executablePath: executable, arguments: args, environment: AdapterSupport.baseEnvironment(executables: [executable], additional: environment), workingDirectory: prefix)
        let preview = AdapterSupport.renderPreview(command)
        let sourcePolicy = installation.evidence.first(where: { $0.label == "Tap" })?.value
        let plan = ActionPlan(installationID: installation.identity, operation: operation, managerInstanceID: installation.identity.managerID, command: command, executableFingerprint: AdapterSupport.executableFingerprint(executable), targetFingerprint: AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]), previewCommand: preview, knownEffects: operation == .remove ? [installation.kind == .cask ? "Homebrew removes the cask-managed installation." : "Homebrew removes the formula installation."] : ["Reviewed Homebrew candidate version: \(updateCandidate ?? "unknown").", "Source policy: \(sourcePolicy ?? "unknown").", "Homebrew may also upgrade outdated dependencies or dependents."], unknownEffects: ["Related files or package effects outside this inventory may be affected."], expectedResult: operation == .remove ? "The package no longer appears in this prefix." : "The selected package version changes after Homebrew completes.", approvedUpdateVersion: updateCandidate, approvedSourcePolicy: operation == .update ? sourcePolicy : nil)
        return .ready(plan)
    }

    public func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        guard plan.installationID == installation.identity, let parts = Self.decodeManagerIdentity(installation.identity.managerID), installation.identity.scopeID == parts.prefix,
              AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint,
              plan.targetFingerprint == AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]) else { return .invalidated(reason: "The Homebrew executable or package identity changed.") }
        guard let prefixResult = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["--prefix"], environment: Self.homebrewReadEnvironment), AdapterSupport.commandSucceeded(prefixResult),
              AdapterSupport.cleanDisplay(prefixResult.standardOutput).map(AdapterSupport.canonicalPath) == parts.prefix else { return .invalidated(reason: "Homebrew's active prefix changed since the plan was prepared.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .homebrew, executablePath: parts.executable, executableFingerprint: plan.executableFingerprint, scope: ManagerScope(id: parts.prefix, displayName: parts.prefix, canonicalRoot: parts.prefix)), using: runner)
        guard fresh.coverage.state == .complete, let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.kind == installation.kind && $0.canonicalLocation == installation.canonicalLocation }),
              current.version == installation.version else { return .invalidated(reason: "The selected Homebrew package changed or could not be found during fresh inventory.") }
        if plan.operation == .update {
            guard plan.approvedUpdateVersion != nil,
                  current.evidence.first(where: { $0.label == "Tap" })?.value == plan.approvedSourcePolicy,
                  let pinned = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["list", "--pinned", installation.kind == .cask ? "--cask" : "--formula"], environment: Self.homebrewReadEnvironment),
                  AdapterSupport.commandSucceeded(pinned),
                  !pinned.standardOutput.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == installation.identity.nativeID }) else { return .invalidated(reason: "Homebrew pin or source policy changed after the update review.") }
            let update = await checkUpdate(installation: current, using: runner)
            guard update.status == .updateAvailable, update.availableVersion == plan.approvedUpdateVersion else { return .invalidated(reason: "Homebrew's local update candidate changed after review.") }
        }
        return .valid(currentTargetFingerprint: AdapterSupport.fingerprint([current.identity.nativeID, current.version, current.canonicalLocation]), currentExecutableFingerprint: plan.executableFingerprint)
    }

    public func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult {
        guard plan.installationID == installation.identity,
              let parts = Self.decodeManagerIdentity(installation.identity.managerID),
              AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint else { return .incomplete }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .homebrew, executablePath: parts.executable, executableFingerprint: plan.executableFingerprint, scope: ManagerScope(id: parts.prefix, displayName: parts.prefix, canonicalRoot: parts.prefix)), using: runner)
        guard fresh.coverage.state == .complete else { return .incomplete }
        guard let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.kind == installation.kind }) else { return plan.operation == .remove ? .verifiedRemoved : .incomplete }
        if plan.operation == .remove { return .stillPresent }
        if current.version == installation.version { return .versionUnchanged }
        return current.version == plan.approvedUpdateVersion ? .verifiedUpdated : .incomplete
    }

    private static func decodeManagerIdentity(_ id: String) -> (executable: String, prefix: String)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "brew" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
    private static let homebrewReadEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
    private static let homebrewUpdateCheckEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
    private static let homebrewMutationEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1"]
}

public enum NPMParser {
    public enum Source: Sendable, Equatable { case publicRegistry, customRegistry, unknown }
    public struct Package: Sendable, Equatable { public var name: String; public var version: String?; public var path: String; public var source: Source }
    public static func isValidPackageName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name.hasPrefix("@") {
            guard parts.count == 2, parts[0].hasPrefix("@"), parts[0].count > 1 else { return false }
            return [String(parts[0].dropFirst()), parts[1]].allSatisfy { $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil }
        }
        return parts.count == 1 && name != "." && name != ".." && name.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil
    }
    public static func parseGlobalList(_ text: String, root: String) -> [Package]? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        guard let rawDependencies = object["dependencies"] else {
            guard AdapterSupport.cleanDisplay(object["name"] as? String) != nil,
                  AdapterSupport.cleanDisplay(object["path"] as? String) != nil,
                  object["extraneous"] is Bool, object["problems"] == nil, object["error"] == nil else { return nil }
            return []
        }
        guard let dependencies = rawDependencies as? [String: Any] else { return nil }
        var packages: [Package] = []
        for (name, raw) in dependencies {
            guard isValidPackageName(name), let row = raw as? [String: Any], row["missing"] == nil, row["invalid"] == nil,
                  let version = AdapterSupport.cleanDisplay(row["version"] as? String) else { return nil }
            let path = AdapterSupport.canonicalPath(root + "/" + name)
            let resolved = row["resolved"] as? String ?? row["_resolved"] as? String
            let source: Source
            if let resolved, let url = URLComponents(string: resolved), let host = url.host?.lowercased() {
                source = url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && host == "registry.npmjs.org" ? .publicRegistry : .customRegistry
            } else { source = .unknown }
            packages.append(Package(name: name, version: version, path: path, source: source))
        }
        return packages.sorted { $0.name < $1.name }
    }
    public static func parseOutdated(_ text: String) -> [String: String]? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (name, raw) in object {
            guard let row = raw as? [String: Any], let current = AdapterSupport.cleanDisplay(row["current"] as? String),
                  let wanted = AdapterSupport.cleanDisplay(row["wanted"] as? String ?? row["latest"] as? String) else { return nil }
            result[name] = wanted == current ? "" : wanted
        }
        return result
    }
}

public struct NPMAdapter: PackageManagerAdapter {
    public let kind: ManagerKind = .npm
    private let explicitExecutables: [String]
    private let explicitNodeExecutables: [String]
    public init(explicitExecutables: [String] = [], explicitNodeExecutables: [String] = []) { self.explicitExecutables = explicitExecutables; self.explicitNodeExecutables = explicitNodeExecutables }
    private var candidates: [String] {
        var known = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            known += versions.prefix(64).map { nvmRoot + "/" + $0 + "/bin/npm" }
        }
        return AdapterSupport.candidateExecutables(named: "npm", known: known, explicit: explicitExecutables)
    }

    public func detect(using runner: any ProcessRunning) async -> DetectionResult {
        let paths = candidates
        guard !paths.isEmpty else { return DetectionResult(presence: .absent, explanation: "No npm executable was found in known locations or configured paths.") }
        var instances: [ManagerInstance] = []; var failed = false
        for path in paths {
            guard let node = nodeForNPM(path), let nodeResult = await AdapterSupport.run(runner, executable: node, arguments: ["--version"]), AdapterSupport.commandSucceeded(nodeResult) else { failed = true; continue }
            let env = ["PATH": URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
            guard let npmVersionResult = await AdapterSupport.run(runner, executable: path, arguments: ["--version"], environment: env), AdapterSupport.commandSucceeded(npmVersionResult),
                  let npmVersion = AdapterSupport.cleanDisplay(npmVersionResult.standardOutput) else { failed = true; continue }
            guard let rootResult = await AdapterSupport.run(runner, executable: path, arguments: ["root", "--global"], environment: env), AdapterSupport.commandSucceeded(rootResult),
                  let rootRaw = AdapterSupport.cleanDisplay(rootResult.standardOutput) else { failed = true; continue }
            let root = AdapterSupport.canonicalPath(rootRaw); let prefix = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().path
            let nodeVersion = AdapterSupport.cleanDisplay(nodeResult.standardOutput) ?? "unknown"
            let id = "npm|\(path)|\(node)|\(prefix)"
            let major = AdapterSupport.semverMajor(npmVersion)
            let supported = major.map { (10...11).contains($0) } ?? false
            instances.append(ManagerInstance(id: id, kind: kind, executablePath: path, executableFingerprint: Self.pairedFingerprint(npm: path, node: node), version: npmVersion, architecture: "node \(nodeVersion)", scope: ManagerScope(id: AdapterSupport.canonicalPath(prefix), displayName: "Global packages · \(prefix)", canonicalRoot: AdapterSupport.canonicalPath(prefix)), presence: supported ? .present : .unsupportedVersion, evidence: [ManagerEvidence(label: "npm", value: path), ManagerEvidence(label: "Node", value: node), ManagerEvidence(label: "Global package root", value: root)], removalSupported: supported, updateSupported: supported))
        }
        if !instances.isEmpty { return DetectionResult(presence: instances.allSatisfy { $0.presence == .unsupportedVersion } ? .unsupportedVersion : .present, instances: instances, explanation: failed ? "Some npm candidates could not be resolved." : nil) }
        return DetectionResult(presence: failed ? .unavailable : .unsupportedVersion, explanation: "npm was found but a matching Node runtime and global root could not be verified.")
    }

    private func nodeForNPM(_ npm: String) -> String? {
        let nodeRootFromNVM: String? = {
            let parts = npm.split(separator: "/")
            guard let nvm = parts.firstIndex(of: ".nvm"), parts.count > nvm + 4, parts[nvm + 1] == "versions", parts[nvm + 2] == "node" else { return nil }
            return "/" + parts.prefix(nvm + 5).joined(separator: "/") + "/bin/node"
        }()
        let prefixNode: [String] = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let explicitAdjacent = explicitExecutables.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("node").path }
        let candidates = explicitNodeExecutables + (nodeRootFromNVM.map { [$0] } ?? []) + explicitAdjacent + prefixNode
        return candidates.first(where: { AdapterSupport.executableExists($0) }).map(AdapterSupport.canonicalPath)
    }

    public func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        let started = Date()
        guard let root = instance.evidence.first(where: { $0.label == "Global package root" })?.value,
              let result = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["ls", "--global", "--depth=0", "--json", "--long", "--prefix", instance.scope.canonicalRoot ?? ""], environment: npmEnvironment(instance)), AdapterSupport.commandSucceeded(result),
              let packages = NPMParser.parseGlobalList(result.standardOutput, root: root) else {
            return AdapterInventoryResult(installations: [], coverage: CoverageSnapshot(id: instance.id, sourceName: "npm", scopeID: instance.scope.id, state: .failed, startedAt: started, completedAt: .now, warning: "npm global inventory failed or returned an unsupported response."))
        }
        let rows = packages.map { pkg in
            let source = pkg.source == .publicRegistry ? "public npm registry" : (pkg.source == .customRegistry ? "custom or private registry" : "unknown registry source")
            return Installation(identity: InstallationID(managerID: instance.id, scopeID: instance.scope.id, nativeID: pkg.name, canonicalLocation: pkg.path), kind: .npmPackage, displayName: pkg.name, version: pkg.version, canonicalLocation: pkg.path, ownership: .verified, evidence: [ManagerEvidence(label: "npm global package", value: pkg.name), ManagerEvidence(label: "Update source", value: source)], removalSupported: instance.removalSupported, updateSupported: instance.updateSupported && pkg.source == .publicRegistry)
        }
        return AdapterInventoryResult(installations: rows, coverage: CoverageSnapshot(id: instance.id, sourceName: "npm", scopeID: instance.scope.id, state: .complete, startedAt: started, completedAt: .now, itemCount: rows.count))
    }

    public func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        guard installation.kind == .npmPackage, installation.ownership == .verified, !installation.isProtected,
              NPMParser.isValidPackageName(installation.identity.nativeID),
              let parts = Self.decode(installation.identity.managerID), parts.prefix == installation.identity.scopeID,
              Self.pairedFingerprint(npm: parts.npm, node: parts.node).contains("missing:") == false else { return .blocked(reason: "The npm installation scope or identifier is invalid.") }
        guard operation == .remove ? installation.removalSupported : installation.updateSupported else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "This npm package's manager version or update source has not been validated for direct actions.") }
        if Self.isOwningRuntimePackage(installation, npm: parts.npm, node: parts.node) {
            let reason = operation == .remove ? "This package owns the selected npm or Node executable. Removing it directly could disable this manager runtime." : "This package owns the selected npm or Node executable. Updating the manager runtime requires a separately reviewed manager upgrade."
            return AdapterSupport.unsupportedGuidance(installation.displayName, reason: reason)
        }
        let args: [String]
        if operation == .remove { args = ["uninstall", "--global", "--ignore-scripts", "--prefix", parts.prefix, installation.identity.nativeID] }
        else {
            let update = await checkUpdate(installation: installation, using: runner)
            guard update.status == .updateAvailable, let latest = update.availableVersion else { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: update.explanation ?? "npm did not provide a verified per-package update candidate.") }
            let oldMajor = AdapterSupport.semverMajor(installation.version), newMajor = AdapterSupport.semverMajor(latest)
            if oldMajor == nil || newMajor == nil || oldMajor != newMajor { return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "npm candidate version \(latest) could be a major-version change or uses an unrecognized version format. Review the configured registry and package policy manually.") }
            args = ["install", "--global", "--prefix", parts.prefix, "--ignore-scripts", "--registry", "https://registry.npmjs.org", "\(installation.identity.nativeID)@\(latest)"]
        }
        let command = ProcessCommand(executablePath: parts.npm, arguments: args, environment: npmEnvironment(instanceID: installation.identity.managerID), workingDirectory: parts.prefix)
        let preview = AdapterSupport.renderPreview(command)
        let plan = ActionPlan(installationID: installation.identity, operation: operation, managerInstanceID: installation.identity.managerID, command: command, executableFingerprint: Self.pairedFingerprint(npm: parts.npm, node: parts.node), targetFingerprint: AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]), previewCommand: preview, knownEffects: ["npm acts within this verified global package scope."] + (operation == .update ? ["Reviewed candidate version: \(args.last ?? "unknown").", "Source policy: public npm registry."] : []), unknownEffects: ["Package effects outside the selected global package may be affected."], expectedResult: operation == .remove ? "The named package is absent from this npm global scope." : "The selected npm package is installed at the reviewed exact version.", approvedUpdateVersion: operation == .update ? Self.updateCandidate(from: args.last) : nil, approvedSourcePolicy: operation == .update ? "https://registry.npmjs.org" : nil)
        return .ready(plan)
    }

    public func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        guard installation.kind == .npmPackage, let parts = Self.decode(installation.identity.managerID), parts.prefix == installation.identity.scopeID else { return UpdateCheckResult(installationID: installation.identity, status: .unsupported, explanation: "The selected npm runtime or scope cannot be verified.") }
        guard installation.evidence.first(where: { $0.label == "Update source" })?.value == "public npm registry" else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "The installed package's resolved source is custom or unknown; npm updates remain guidance-only.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .npm, executablePath: parts.npm, executableFingerprint: Self.pairedFingerprint(npm: parts.npm, node: parts.node), scope: ManagerScope(id: parts.prefix, displayName: parts.prefix, canonicalRoot: parts.prefix), evidence: [ManagerEvidence(label: "Global package root", value: parts.root)]), using: runner)
        guard fresh.coverage.state == .complete, let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.canonicalLocation == installation.canonicalLocation && $0.version == installation.version }),
              current.evidence.first(where: { $0.label == "Update source" })?.value == "public npm registry" else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "The selected npm package is no longer verifiable as a public-registry package in this global prefix.") }
        guard await hasPublicRegistryConfigured(parts: parts, packageName: installation.identity.nativeID, runner: runner) else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "npm is configured for a custom or unverified registry; update manually after reviewing its source.") }
        guard let result = await AdapterSupport.run(runner, executable: parts.npm, arguments: ["outdated", "--global", "--depth=0", "--json", "--prefix", parts.prefix, installation.identity.nativeID], environment: npmEnvironment(instanceID: installation.identity.managerID)),
              (result.exitCode == 0 || result.exitCode == 1), !result.didTimeOut, !result.wasCancelled, !result.outputWasTruncated,
              let updates = NPMParser.parseOutdated(result.standardOutput) else { return UpdateCheckResult(installationID: installation.identity, status: .failed, currentVersion: installation.version, explanation: "npm update status could not be parsed.") }
        guard let candidate = updates[installation.identity.nativeID] else { return UpdateCheckResult(installationID: installation.identity, status: .upToDate, currentVersion: installation.version, explanation: "npm reported no update for this package in the selected global scope.") }
        guard !candidate.isEmpty else { return UpdateCheckResult(installationID: installation.identity, status: .upToDate, currentVersion: installation.version) }
        return UpdateCheckResult(installationID: installation.identity, status: .updateAvailable, currentVersion: installation.version, availableVersion: candidate, explanation: "npm reports an update within the configured version policy.")
    }

    public func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID), parts.prefix == installation.identity.scopeID, Self.pairedFingerprint(npm: parts.npm, node: parts.node) == plan.executableFingerprint,
              plan.targetFingerprint == AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]) else { return .invalidated(reason: "The npm executable or package scope changed.") }
        let freshInstance = ManagerInstance(id: installation.identity.managerID, kind: .npm, executablePath: parts.npm, executableFingerprint: plan.executableFingerprint, scope: ManagerScope(id: parts.prefix, displayName: parts.prefix, canonicalRoot: parts.prefix), evidence: [ManagerEvidence(label: "Global package root", value: parts.root)])
        let fresh = await inventory(instance: freshInstance, using: runner)
        guard fresh.coverage.state == .complete, let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.canonicalLocation == installation.canonicalLocation }), current.version == installation.version else { return .invalidated(reason: "The npm package changed or could not be re-listed in its global prefix.") }
        if plan.operation == .remove && Self.isOwningRuntimePackage(current, npm: parts.npm, node: parts.node) { return .invalidated(reason: "The selected package now owns the npm or Node runtime executable.") }
        if plan.operation == .update {
            guard plan.approvedSourcePolicy == "https://registry.npmjs.org", let approved = plan.approvedUpdateVersion else { return .invalidated(reason: "The npm update plan has no bound candidate or source policy.") }
            let update = await checkUpdate(installation: current, using: runner)
            guard update.status == .updateAvailable, update.availableVersion == approved,
                  await hasPublicRegistryConfigured(parts: parts, packageName: installation.identity.nativeID, runner: runner) else { return .invalidated(reason: "The npm update candidate or registry policy changed after review.") }
        }
        return .valid(currentTargetFingerprint: AdapterSupport.fingerprint([current.identity.nativeID, current.version, current.canonicalLocation]), currentExecutableFingerprint: plan.executableFingerprint)
    }
    public func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID),
              Self.pairedFingerprint(npm: parts.npm, node: parts.node) == plan.executableFingerprint,
              let result = await AdapterSupport.run(runner, executable: parts.npm, arguments: ["ls", "--global", "--depth=0", "--json", "--long", "--prefix", parts.prefix], environment: npmEnvironment(instanceID: installation.identity.managerID)), AdapterSupport.commandSucceeded(result), let packages = NPMParser.parseGlobalList(result.standardOutput, root: parts.root) else { return .incomplete }
        let item = packages.first { $0.name == installation.identity.nativeID }
        if plan.operation == .remove { return item == nil ? .verifiedRemoved : .stillPresent }
        guard let item else { return .incomplete }
        return item.version == installation.version ? .versionUnchanged : (item.version == plan.approvedUpdateVersion ? .verifiedUpdated : .incomplete)
    }
    private func npmEnvironment(_ instance: ManagerInstance) -> [String: String] { npmEnvironment(instanceID: instance.id) }
    private func npmEnvironment(instanceID: String) -> [String: String] { Self.decode(instanceID).map { AdapterSupport.baseEnvironment(executables: [$0.node, $0.npm]) } ?? [:] }
    private static func decode(_ id: String) -> (npm: String, node: String, prefix: String, root: String)? {
        let p = id.split(separator: "|", omittingEmptySubsequences: false); guard p.count == 4, p[0] == "npm" else { return nil }
        let root = URL(fileURLWithPath: String(p[3])).appendingPathComponent("lib/node_modules").path
        return (String(p[1]), String(p[2]), String(p[3]), root)
    }
    private static func pairedFingerprint(npm: String, node: String) -> String { AdapterSupport.fingerprint([AdapterSupport.executableFingerprint(npm), AdapterSupport.executableFingerprint(node)]) }
    private static func updateCandidate(from argument: String?) -> String? {
        guard let argument, let separator = argument.lastIndex(of: "@"), separator < argument.endIndex else { return nil }
        return String(argument[argument.index(after: separator)...])
    }
    private static func isOwningRuntimePackage(_ installation: Installation, npm: String, node: String) -> Bool {
        if installation.identity.nativeID == "npm" { return true }
        let target = AdapterSupport.canonicalPath(installation.canonicalLocation)
        for binary in [npm, node] {
            let canonical = AdapterSupport.canonicalPath(binary)
            let components = canonical.split(separator: "/").map(String.init)
            guard let marker = components.lastIndex(of: "node_modules"), marker + 1 < components.count else { continue }
            var packageComponents = Array(components[...marker])
            packageComponents.append(components[marker + 1])
            if components[marker + 1].hasPrefix("@"), marker + 2 < components.count { packageComponents.append(components[marker + 2]) }
            let root = "/" + packageComponents.joined(separator: "/")
            if target == root || target.hasPrefix(root + "/") { return true }
        }
        return false
    }

    private func hasPublicRegistryConfigured(parts: (npm: String, node: String, prefix: String, root: String), packageName: String, runner: any ProcessRunning) async -> Bool {
        let baseEnvironment = npmEnvironment(instanceID: "npm|\(parts.npm)|\(parts.node)|\(parts.prefix)")
        func query(_ key: String) async -> String? {
            guard let result = await AdapterSupport.run(runner, executable: parts.npm, arguments: ["config", "get", key, "--prefix", parts.prefix], environment: baseEnvironment), AdapterSupport.commandSucceeded(result) else { return nil }
            return AdapterSupport.cleanDisplay(result.standardOutput)
        }
        var raw: String?
        if packageName.hasPrefix("@"), let slash = packageName.firstIndex(of: "/") {
            raw = await query(String(packageName[..<slash]) + ":registry")
        }
        if raw == nil || raw == "undefined" || raw == "null" { raw = await query("registry") }
        guard let registry = raw, let url = URLComponents(string: registry),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "registry.npmjs.org", url.user == nil, url.password == nil else { return false }
        return true
    }
}

public enum PipxParser {
    public struct Environment: Sendable, Equatable { public var name: String; public var package: String; public var version: String?; public var injected: [String]; public var hasCustomSource: Bool }
    public static func parseList(_ text: String) -> [Environment]? {
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any] else { return nil }
        // pipx 1.4+ --json list snapshot and current result envelopes have different schemas.
        let rows: [String: Any]
        if let snapshot = object["venvs"] as? [String: Any] { rows = snapshot }
        else if object["pipx_result_version"] as? String == "1", let command = object["command"] as? [String], command.contains("list"), object["status"] as? String == "success", (object["errors"] as? [Any] ?? []).isEmpty, let data = object["data"] as? [String: Any], let venvs = data["venvs"] as? [String: Any] { rows = venvs }
        else { return nil }
        var result: [Environment] = []
        for (env, raw) in rows {
            guard let row = raw as? [String: Any] else { return nil }
            let metadata: [String: Any]
            if let rawMetadata = row["metadata"] { guard let parsed = rawMetadata as? [String: Any] else { return nil }; metadata = parsed }
            else { metadata = row }
            guard let main = metadata["main_package"] as? [String: Any] ?? row["main_package"] as? [String: Any] else { return nil }
            let package = AdapterSupport.cleanDisplay(main["package"] as? String) ?? env
            let version = AdapterSupport.cleanDisplay(main["package_version"] as? String)
            let injectedRaw = metadata["injected_packages"] as? [String: Any] ?? row["injected_packages"] as? [String: Any] ?? [:]
            guard injectedRaw.values.allSatisfy({ $0 is [String: Any] }) else { return nil }
            let injected = injectedRaw.keys.sorted()
            let source = AdapterSupport.cleanDisplay(main["package_or_url"] as? String)
            let args: [String]
            if let rawArgs = main["pip_args"] { guard let parsed = rawArgs as? [String] else { return nil }; args = parsed }
            else { args = [] }
            let customArgs = args.contains { $0 == "-i" || $0 == "--index-url" || $0 == "--extra-index-url" || $0.hasPrefix("--index-url=") || $0.hasPrefix("--extra-index-url=") || $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            result.append(Environment(name: env, package: package, version: version, injected: injected, hasCustomSource: (source.map { $0 != package } ?? true) || customArgs))
        }
        return result.sorted { $0.name < $1.name }
    }

    public struct Outdated: Sendable, Equatable { public var environment: String; public var current: String?; public var available: String? }
    public static func parseOutdated(_ text: String) -> [Outdated]? {
        let command = (AdapterSupport.parsedJSON(text) as? [String: Any])?["command"] as? [String]
        let normalizedCommand = command?.filter { $0 != "--skip-maintenance" }
        guard let object = AdapterSupport.parsedJSON(text) as? [String: Any], object["pipx_result_version"] as? String == "1",
              normalizedCommand == ["list", "--outdated"], object["status"] as? String == "success",
              (object["errors"] as? [Any] ?? []).isEmpty,
              let data = object["data"] as? [String: Any], let rows = data["outdated"] ?? data["environments"] ?? data["venvs"] else { return nil }
        if let array = rows as? [[String: Any]] {
            var result: [Outdated] = []
            for row in array {
                guard let name = AdapterSupport.cleanDisplay(row["environment"] as? String ?? row["name"] as? String ?? row["venv"] as? String) else { return nil }
                result.append(Outdated(environment: name, current: AdapterSupport.cleanDisplay(row["current_version"] as? String ?? row["current"] as? String), available: AdapterSupport.cleanDisplay(row["available_version"] as? String ?? row["latest_version"] as? String ?? row["latest"] as? String)))
            }
            return result
        }
        if let dict = rows as? [String: Any] {
            var result: [Outdated] = []
            for (name, raw) in dict {
                guard let row = raw as? [String: Any],
                      let current = AdapterSupport.cleanDisplay(row["current_version"] as? String ?? row["current"] as? String),
                      let available = AdapterSupport.cleanDisplay(row["available_version"] as? String ?? row["latest_version"] as? String ?? row["latest"] as? String) else { return nil }
                result.append(Outdated(environment: name, current: current, available: available))
            }
            return result.sorted { $0.environment < $1.environment }
        }
        return nil
    }
}

public struct PipxAdapter: PackageManagerAdapter {
    public let kind: ManagerKind = .pipx
    private let explicitExecutables: [String]
    private let explicitHomes: [String]
    public init(explicitExecutables: [String] = [], explicitHomes: [String] = []) { self.explicitExecutables = explicitExecutables; self.explicitHomes = explicitHomes }
    private var candidates: [String] { AdapterSupport.candidateExecutables(named: "pipx", known: ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx", "/usr/bin/pipx", NSHomeDirectory() + "/.local/bin/pipx"], explicit: explicitExecutables) }
    public func detect(using runner: any ProcessRunning) async -> DetectionResult {
        let paths = candidates; guard !paths.isEmpty else { return DetectionResult(presence: .absent, explanation: "No pipx executable was found in known locations or configured paths.") }
        var instances: [ManagerInstance] = []; var failed = false
        for path in paths {
            guard let versionResult = await AdapterSupport.run(runner, executable: path, arguments: ["--version"]), AdapterSupport.commandSucceeded(versionResult),
                  let version = AdapterSupport.cleanDisplay(versionResult.standardOutput) else { failed = true; continue }
            var homes = explicitHomes
            if let env = ProcessInfo.processInfo.environment["PIPX_HOME"], env.hasPrefix("/") { homes.append(env) }
            if homes.isEmpty { homes = [NSHomeDirectory() + "/.local/share/pipx"] }
            for rawHome in homes {
                guard rawHome.hasPrefix("/") else { failed = true; continue }
                let home = AdapterSupport.canonicalPath(rawHome); let env = ["PIPX_HOME": home, "PATH": URL(fileURLWithPath: path).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
                guard let list = await AdapterSupport.run(runner, executable: path, arguments: ["list", "--skip-maintenance", "--json"], environment: env), AdapterSupport.commandSucceeded(list),
                      let parsed = PipxParser.parseList(list.standardOutput) else { failed = true; continue }
                let id = "pipx|\(path)|\(home)"
                let major = AdapterSupport.semverMajor(version)
                let supported = major == 1
                instances.append(ManagerInstance(id: id, kind: kind, executablePath: path, executableFingerprint: AdapterSupport.executableFingerprint(path), version: version, scope: ManagerScope(id: home, displayName: "pipx · \(home)", canonicalRoot: home, isExplicitlySelected: explicitHomes.contains(rawHome)), presence: supported ? .present : .unsupportedVersion, evidence: [ManagerEvidence(label: "pipx", value: path), ManagerEvidence(label: "PIPX_HOME", value: home), ManagerEvidence(label: "Environment count", value: String(parsed.count))], removalSupported: supported, updateSupported: supported))
            }
        }
        if !instances.isEmpty { return DetectionResult(presence: instances.allSatisfy { $0.presence == .unsupportedVersion } ? .unsupportedVersion : .present, instances: instances, explanation: failed ? "Some pipx candidates or homes could not be inventoried." : nil) }
        return DetectionResult(presence: .unavailable, explanation: "pipx executable was found, but no pipx home could be inventoried.")
    }
    public func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        let started = Date(); let home = instance.scope.canonicalRoot ?? ""; let env = environment(instance.executablePath, home)
        guard let result = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["list", "--skip-maintenance", "--json"], environment: env), AdapterSupport.commandSucceeded(result), let packages = PipxParser.parseList(result.standardOutput) else {
            return AdapterInventoryResult(installations: [], coverage: CoverageSnapshot(id: instance.id, sourceName: "pipx", scopeID: instance.scope.id, state: .failed, startedAt: started, completedAt: .now, warning: "pipx inventory failed or returned an unsupported schema."))
        }
        let rows = packages.map { pkg in
            let location = AdapterSupport.canonicalPath(home + "/venvs/" + pkg.name)
            let source = ManagerEvidence(label: "Update source", value: pkg.hasCustomSource ? "Custom or unknown" : "PyPI package name")
            let evidence = [ManagerEvidence(label: "pipx environment", value: pkg.name), source] + pkg.injected.map { ManagerEvidence(label: "Injected package", value: $0) }
            return Installation(identity: InstallationID(managerID: instance.id, scopeID: home, nativeID: pkg.name, canonicalLocation: location), kind: .pipxEnvironment, displayName: pkg.package, version: pkg.version, canonicalLocation: location, ownership: .verified, evidence: evidence, removalSupported: instance.removalSupported, updateSupported: instance.updateSupported)
        }
        return AdapterInventoryResult(installations: rows, coverage: CoverageSnapshot(id: instance.id, sourceName: "pipx", scopeID: instance.scope.id, state: .complete, startedAt: started, completedAt: .now, itemCount: rows.count))
    }
    public func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        guard operation == .remove ? installation.removalSupported : installation.updateSupported,
              installation.kind == .pipxEnvironment, installation.ownership == .verified, !installation.isProtected,
              AdapterSupport.isSafeNativeID(installation.identity.nativeID, allowed: #"[A-Za-z0-9._-]+"#),
              let parts = Self.decode(installation.identity.managerID), parts.home == installation.identity.scopeID,
              AdapterSupport.rootIsWithin(installation.canonicalLocation, root: parts.home + "/venvs") else { return .blocked(reason: "The pipx environment path or identity does not match its selected home.") }
        if operation == .remove && Self.pathIsOwnedByInstallation(parts.executable, installation: installation) {
            return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "The selected pipx executable is inside this environment. Use another verified pipx installation to remove it.")
        }
        let env = environment(parts.executable, parts.home)
        if operation == .update {
            let result = await checkUpdate(installation: installation, using: runner)
            let candidate = result.availableVersion.map { " Candidate reported: \($0)." } ?? ""
            return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "pipx reuses saved install options and source details for upgrade, which cannot currently be constrained to the reviewed candidate and normalized source policy.\(candidate) Review the saved source and pin, then run pipx upgrade manually.")
        }
        let args = ["uninstall", "--skip-maintenance", installation.identity.nativeID]
        let command = ProcessCommand(executablePath: parts.executable, arguments: args, environment: AdapterSupport.baseEnvironment(executables: [parts.executable], additional: env), workingDirectory: parts.home)
        return .ready(ActionPlan(installationID: installation.identity, operation: .remove, managerInstanceID: installation.identity.managerID, command: command, executableFingerprint: AdapterSupport.executableFingerprint(parts.executable), targetFingerprint: AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]), previewCommand: AdapterSupport.renderPreview(command), knownEffects: ["pipx removes the selected virtual environment and its exposed applications.", "Injected packages in the environment are removed with it."], unknownEffects: ["pipx metadata may include private installation sources; no raw metadata is retained."], expectedResult: "The named environment is absent from the selected PIPX_HOME."))
    }

    public func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        guard installation.kind == .pipxEnvironment, let parts = Self.decode(installation.identity.managerID), parts.home == installation.identity.scopeID else { return UpdateCheckResult(installationID: installation.identity, status: .unsupported, explanation: "The selected pipx home cannot be verified.") }
        guard installation.evidence.first(where: { $0.label == "Update source" })?.value == "PyPI package name" else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "This environment has a custom or unknown package source.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .pipx, executablePath: parts.executable, executableFingerprint: AdapterSupport.executableFingerprint(parts.executable), scope: ManagerScope(id: parts.home, displayName: parts.home, canonicalRoot: parts.home)), using: runner)
        guard fresh.coverage.state == .complete, fresh.installations.contains(where: { $0.identity.nativeID == installation.identity.nativeID && $0.version == installation.version }) else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "The selected pipx environment is no longer verifiable.") }
        guard let result = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["list", "--skip-maintenance", "--outdated", "--output", "json", installation.identity.nativeID], environment: environment(parts.executable, parts.home)), AdapterSupport.commandSucceeded(result),
              let outdated = PipxParser.parseOutdated(result.standardOutput) else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "pipx returned an unsupported or partial outdated result.") }
        guard let candidate = outdated.first(where: { $0.environment == installation.identity.nativeID }) else { return UpdateCheckResult(installationID: installation.identity, status: .upToDate, currentVersion: installation.version, explanation: "pipx reported no available update for this environment.") }
        guard let available = candidate.available else { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "pipx did not provide a candidate version for this environment.") }
        if let reportedCurrent = candidate.current, reportedCurrent != installation.version { return UpdateCheckResult(installationID: installation.identity, status: .unknown, currentVersion: installation.version, explanation: "pipx's outdated result did not match the freshly inventoried current version.") }
        return UpdateCheckResult(installationID: installation.identity, status: .updateAvailable, currentVersion: candidate.current ?? installation.version, availableVersion: available, explanation: "pipx reported an update for this saved package source.")
    }
    public func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID), AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint,
              AdapterSupport.rootIsWithin(installation.canonicalLocation, root: parts.home + "/venvs"), plan.targetFingerprint == AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]) else { return .invalidated(reason: "The pipx executable, home or environment changed.") }
        if plan.operation == .remove && Self.pathIsOwnedByInstallation(parts.executable, installation: installation) { return .invalidated(reason: "The selected pipx executable is inside the environment scheduled for removal.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .pipx, executablePath: parts.executable, executableFingerprint: plan.executableFingerprint, scope: ManagerScope(id: parts.home, displayName: parts.home, canonicalRoot: parts.home)), using: runner)
        guard fresh.coverage.state == .complete, let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.canonicalLocation == installation.canonicalLocation }), current.version == installation.version else { return .invalidated(reason: "The pipx environment changed or could not be re-listed in its selected home.") }
        return .valid(currentTargetFingerprint: AdapterSupport.fingerprint([current.identity.nativeID, current.version, current.canonicalLocation]), currentExecutableFingerprint: plan.executableFingerprint)
    }
    public func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID),
              AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint,
              let result = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["list", "--skip-maintenance", "--json"], environment: environment(parts.executable, parts.home)), AdapterSupport.commandSucceeded(result), let rows = PipxParser.parseList(result.standardOutput) else { return .incomplete }
        guard let current = rows.first(where: { $0.name == installation.identity.nativeID }) else { return plan.operation == .remove ? .verifiedRemoved : .incomplete }
        if plan.operation == .remove { return .stillPresent }
        return current.version == installation.version ? .versionUnchanged : .verifiedUpdated
    }
    private func environment(_ executable: String, _ home: String) -> [String: String] { ["PIPX_HOME": home] }
    private static func decode(_ id: String) -> (executable: String, home: String)? { let p = id.split(separator: "|", omittingEmptySubsequences: false); guard p.count == 3, p[0] == "pipx" else { return nil }; return (String(p[1]), String(p[2])) }
    private static func pathIsOwnedByInstallation(_ executable: String, installation: Installation) -> Bool {
        let tool = AdapterSupport.canonicalPath(executable), environment = AdapterSupport.canonicalPath(installation.canonicalLocation)
        return tool == environment || tool.hasPrefix(environment + "/")
    }
}

public enum CargoParser {
    public struct Package: Sendable, Equatable { public var name: String; public var version: String; public var binaries: [String] }
    public static func parseInstallList(_ text: String) -> [Package]? {
        var rows: [Package] = []; var currentName: String?; var currentVersion: String?; var binaries: [String] = []
        func flush() { if let n = currentName, let v = currentVersion { rows.append(Package(name: n, version: v, binaries: binaries)) } }
        for line in text.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            if line == "Installed packages:" { continue }
            if let match = line.range(of: #"^([A-Za-z0-9_-]+) v([^ ]+):$"#, options: .regularExpression) {
                flush(); let header = String(line[match]); let parts = header.dropLast().components(separatedBy: " v"); currentName = parts.first; currentVersion = parts.count > 1 ? parts[1] : nil; binaries = []
            } else if line.first == " " || line.first == "\t" {
                let binary = line.trimmingCharacters(in: .whitespaces)
                guard AdapterSupport.isSafeNativeID(binary, allowed: #"[A-Za-z0-9._+-]+"#) else { return nil }
                binaries.append(binary)
            } else { return nil }
        }
        flush(); return rows
    }
}

public struct CargoAdapter: PackageManagerAdapter {
    public let kind: ManagerKind = .cargo
    private let explicitExecutables: [String]; private let explicitRoots: [String]
    public init(explicitExecutables: [String] = [], explicitRoots: [String] = []) { self.explicitExecutables = explicitExecutables; self.explicitRoots = explicitRoots }
    private var candidates: [String] { AdapterSupport.candidateExecutables(named: "cargo", known: ["/opt/homebrew/bin/cargo", "/usr/local/bin/cargo", NSHomeDirectory() + "/.cargo/bin/cargo"], explicit: explicitExecutables) }
    public func detect(using runner: any ProcessRunning) async -> DetectionResult {
        let paths = candidates; guard !paths.isEmpty else { return DetectionResult(presence: .absent, explanation: "No Cargo executable was found in known locations or configured paths.") }
        var instances: [ManagerInstance] = []; var failed = false; var sawCargo = false
        let envRoot = ProcessInfo.processInfo.environment["CARGO_INSTALL_ROOT"]
        let roots = explicitRoots + (envRoot.map { [$0] } ?? [])
        for path in paths {
            guard let versionResult = await AdapterSupport.run(runner, executable: path, arguments: ["--version"]), AdapterSupport.commandSucceeded(versionResult),
                  let version = AdapterSupport.cleanDisplay(versionResult.standardOutput) else { failed = true; continue }
            sawCargo = true
            for raw in roots where raw.hasPrefix("/") && FileManager.default.fileExists(atPath: raw) {
                let root = AdapterSupport.canonicalPath(raw)
                guard let listing = await AdapterSupport.run(runner, executable: path, arguments: ["install", "--list", "--root", root]), AdapterSupport.commandSucceeded(listing), CargoParser.parseInstallList(listing.standardOutput) != nil else { failed = true; continue }
                let id = "cargo|\(path)|\(root)"
                let supported = AdapterSupport.semverMajor(version).map { $0 == 1 } ?? false
                instances.append(ManagerInstance(id: id, kind: kind, executablePath: path, executableFingerprint: AdapterSupport.executableFingerprint(path), version: version, scope: ManagerScope(id: root, displayName: "Cargo install root · \(root)", canonicalRoot: root, isExplicitlySelected: true), presence: supported ? .present : .unsupportedVersion, evidence: [ManagerEvidence(label: "Cargo", value: path), ManagerEvidence(label: "Install root", value: root)], removalSupported: supported, updateSupported: false))
            }
        }
        if !instances.isEmpty { return DetectionResult(presence: instances.allSatisfy { $0.presence == .unsupportedVersion } ? .unsupportedVersion : .present, instances: instances, explanation: "Cargo is inventoried only under explicit roots; update checks remain guidance-only.") }
        if sawCargo && roots.isEmpty { return DetectionResult(presence: .present, explanation: "Cargo is present. Select an explicit Cargo installation root to enable inventory.") }
        return DetectionResult(presence: failed ? .unavailable : .absent, explanation: "Cargo was found, but no explicit installation root could be inventoried.")
    }
    public func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        let started = Date(); let root = instance.scope.canonicalRoot ?? ""
        guard root.hasPrefix("/"), let result = await AdapterSupport.run(runner, executable: instance.executablePath, arguments: ["install", "--list", "--root", root]), AdapterSupport.commandSucceeded(result), let packages = CargoParser.parseInstallList(result.standardOutput) else {
            return AdapterInventoryResult(installations: [], coverage: CoverageSnapshot(id: instance.id, sourceName: "Cargo", scopeID: instance.scope.id, state: .failed, startedAt: started, completedAt: .now, warning: "Cargo inventory output could not be parsed."))
        }
        let rows = packages.map { package in
            let location = AdapterSupport.canonicalPath(root + "/bin")
            let evidence = [ManagerEvidence(label: "Installed binaries", value: package.binaries.joined(separator: ", ")), ManagerEvidence(label: "Source", value: "unknown")]
            return Installation(identity: InstallationID(managerID: instance.id, scopeID: root, nativeID: package.name, canonicalLocation: location), kind: .cargoPackage, displayName: package.name, version: package.version, canonicalLocation: location, ownership: .verified, evidence: evidence, removalSupported: instance.removalSupported)
        }
        return AdapterInventoryResult(installations: rows, coverage: CoverageSnapshot(id: instance.id, sourceName: "Cargo", scopeID: instance.scope.id, state: .complete, startedAt: started, completedAt: .now, itemCount: rows.count))
    }
    public func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        guard operation == .remove, installation.removalSupported, installation.kind == .cargoPackage, installation.ownership == .verified, !installation.isProtected,
              AdapterSupport.isSafeNativeID(installation.identity.nativeID, allowed: #"[A-Za-z0-9_-]+"#),
              let parts = Self.decode(installation.identity.managerID), parts.root == installation.identity.scopeID,
              AdapterSupport.rootIsWithin(installation.canonicalLocation, root: parts.root) else { return .blocked(reason: "The Cargo package or explicit installation root is invalid.") }
        let ownedBinaries = installation.evidence.first(where: { $0.label == "Installed binaries" })?.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let managerAlias = URL(fileURLWithPath: parts.executable).lastPathComponent
        let resolvedAlias = URL(fileURLWithPath: AdapterSupport.canonicalPath(parts.executable)).lastPathComponent
        if (ownedBinaries.contains("cargo") || ownedBinaries.contains("rustup")),
           AdapterSupport.rootIsWithin(parts.executable, root: parts.root + "/bin"),
           ownedBinaries.contains(managerAlias) || ownedBinaries.contains(resolvedAlias) {
            return AdapterSupport.unsupportedGuidance(installation.displayName, reason: "This Cargo package owns the selected Cargo or rustup executable. Use another verified Cargo runtime to remove it.")
        }
        let args = ["uninstall", "--root", parts.root, installation.identity.nativeID]
        let cargoHome = ProcessInfo.processInfo.environment["CARGO_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory() + "/.cargo"
        var additions = ["CARGO_HOME": cargoHome]
        if let rustupHome = ProcessInfo.processInfo.environment["RUSTUP_HOME"], rustupHome.hasPrefix("/") { additions["RUSTUP_HOME"] = rustupHome }
        let environment = AdapterSupport.baseEnvironment(executables: [parts.executable], additional: additions)
        let command = ProcessCommand(executablePath: parts.executable, arguments: args, environment: environment, workingDirectory: parts.root)
        return .ready(ActionPlan(installationID: installation.identity, operation: .remove, managerInstanceID: installation.identity.managerID, command: command, executableFingerprint: AdapterSupport.executableFingerprint(parts.executable), targetFingerprint: AdapterSupport.fingerprint([installation.identity.nativeID, installation.version, installation.canonicalLocation]), previewCommand: AdapterSupport.renderPreview(command), knownEffects: installation.evidence.filter { $0.label == "Installed binaries" }.map { "Cargo removes these binaries: \($0.value)." }, unknownEffects: ["Cargo installation source is unknown; the package's build origin is not retained by `cargo install --list`."], expectedResult: "The package and its installed binaries are absent from this explicit Cargo root."))
    }
    public func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        UpdateCheckResult(installationID: installation.identity, status: .unsupported, currentVersion: installation.version, explanation: "Cargo update checks are guidance-only because installed source mappings are not available.")
    }
    public func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID), parts.root == installation.identity.scopeID,
              AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint,
              AdapterSupport.canonicalPath(parts.root) == parts.root else { return .invalidated(reason: "The Cargo executable or explicit root changed.") }
        let fresh = await inventory(instance: ManagerInstance(id: installation.identity.managerID, kind: .cargo, executablePath: parts.executable, executableFingerprint: plan.executableFingerprint, scope: ManagerScope(id: parts.root, displayName: parts.root, canonicalRoot: parts.root)), using: runner)
        guard fresh.coverage.state == .complete, let current = fresh.installations.first(where: { $0.identity.nativeID == installation.identity.nativeID && $0.canonicalLocation == installation.canonicalLocation }), current.version == installation.version else { return .invalidated(reason: "The Cargo package changed or could not be re-listed under its explicit root.") }
        let currentBinaries = current.evidence.first(where: { $0.label == "Installed binaries" })?.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let managerAlias = URL(fileURLWithPath: parts.executable).lastPathComponent
        let resolvedAlias = URL(fileURLWithPath: AdapterSupport.canonicalPath(parts.executable)).lastPathComponent
        if AdapterSupport.rootIsWithin(parts.executable, root: parts.root + "/bin"),
           currentBinaries.contains(managerAlias) || currentBinaries.contains(resolvedAlias) {
            return .invalidated(reason: "The refreshed Cargo package now owns the selected Cargo runtime executable.")
        }
        return .valid(currentTargetFingerprint: plan.targetFingerprint, currentExecutableFingerprint: plan.executableFingerprint)
    }
    public func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult {
        guard plan.installationID == installation.identity, let parts = Self.decode(installation.identity.managerID),
              AdapterSupport.executableFingerprint(parts.executable) == plan.executableFingerprint,
              let result = await AdapterSupport.run(runner, executable: parts.executable, arguments: ["install", "--list", "--root", parts.root]), AdapterSupport.commandSucceeded(result), let packages = CargoParser.parseInstallList(result.standardOutput) else { return .incomplete }
        guard let current = packages.first(where: { $0.name == installation.identity.nativeID }) else { return plan.operation == .remove ? .verifiedRemoved : .incomplete }
        if plan.operation == .remove { return .stillPresent }
        return current.version == installation.version ? .versionUnchanged : .verifiedUpdated
    }
    private static func decode(_ id: String) -> (executable: String, root: String)? { let p = id.split(separator: "|", omittingEmptySubsequences: false); guard p.count == 3, p[0] == "cargo" else { return nil }; return (String(p[1]), String(p[2])) }
}

public struct AppBundleAdapter: PackageManagerAdapter {
    public let kind: ManagerKind = .appBundle
    private let explicitRoots: [String]
    public init(explicitRoots: [String] = []) { self.explicitRoots = explicitRoots }
    private var roots: [String] { Array(Set(["/Applications", NSHomeDirectory() + "/Applications"] + explicitRoots)).filter { $0.hasPrefix("/") }.sorted() }

    public func detect(using runner: any ProcessRunning) async -> DetectionResult {
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return DetectionResult(presence: .absent, explanation: "No standard or explicitly selected Applications folder is available.") }
        let instances = existing.map { root in
            let canonical = AdapterSupport.canonicalPath(root)
            return ManagerInstance(id: "apps|\(canonical)", kind: .appBundle, executablePath: "/usr/bin/true", executableFingerprint: "metadata-only", scope: ManagerScope(id: canonical, displayName: canonical, canonicalRoot: canonical, isExplicitlySelected: explicitRoots.contains(root)), evidence: [ManagerEvidence(label: "Applications folder", value: canonical)])
        }
        return DetectionResult(presence: .present, instances: instances)
    }

    public func inventory(instance: ManagerInstance, using runner: any ProcessRunning) async -> AdapterInventoryResult {
        let started = Date(), root = instance.scope.canonicalRoot ?? ""
        let result = AppBundleInventory.scan(roots: [root], managerID: instance.id)
        return AdapterInventoryResult(installations: result.installations, coverage: CoverageSnapshot(id: instance.id, sourceName: "Mac apps", scopeID: instance.scope.id, state: result.partial ? .partial : .complete, startedAt: started, completedAt: .now, itemCount: result.installations.count, warning: result.warning))
    }

    public func prepare(operation: ManagedOperation, installation: Installation, using runner: any ProcessRunning) async -> PlanDecision {
        if installation.isProtected { return .blocked(reason: installation.protectionReason ?? "This Apple or system app is protected from removal.") }
        let receipt = installation.evidence.contains(where: { $0.label == "App Store receipt" })
        if receipt {
            let guide = RemovalGuidance(title: "Remove \(installation.displayName)", steps: ["This app has an App Store receipt. Use the App Store's account and installed-app workflow to remove it.", "The app bundle is at \(installation.canonicalLocation). This guidance does not remove related documents, preferences, or support files."], sourceURL: URL(string: "https://support.apple.com/en-us/102610"), isVerified: false)
            return .guidance(guide, reason: "App Store receipt evidence requires the App Store removal workflow.")
        }
        let guide = RemovalGuidance(title: "Move \(installation.displayName) to the Trash", steps: ["Quit \(installation.displayName) if it is running.", "Check the developer's documentation or uninstaller first. If there is no uninstaller, open the exact bundle path in Finder: \(installation.canonicalLocation).", "Select that .app bundle in Finder and choose File → Move to Trash. If Finder denies access, stop and ask the app developer or administrator. Do not remove files from Library folders; this guide covers only the app bundle."], sourceURL: URL(string: "https://support.apple.com/en-us/102610"), isVerified: false)
        return .guidance(guide, reason: "App-bundle removal is guidance-only; no direct Trash action is enabled.")
    }
    public func checkUpdate(installation: Installation, using runner: any ProcessRunning) async -> UpdateCheckResult {
        UpdateCheckResult(installationID: installation.identity, status: .unsupported, currentVersion: installation.version, explanation: "This app bundle has no verified update source mapping.")
    }
    public func revalidate(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> PreflightResult { .invalidated(reason: "App-bundle direct removal is not enabled.") }
    public func verify(plan: ActionPlan, installation: Installation, using runner: any ProcessRunning) async -> VerificationResult { .incomplete }
}

public struct AppBundleScanResult: Sendable {
    public var installations: [Installation]; public var partial: Bool; public var warning: String?
}

public enum AppBundleInventory {
    /// Links only a manager-reported absolute app path to the exact discovered bundle path.
    /// Display names and bundle names are never used as matching evidence.
    public static func isVerifiedCaskLink(cask: Installation, appBundle: Installation) -> Bool {
        guard cask.kind == .cask, appBundle.kind == .appBundle,
              let path = cask.evidence.first(where: { $0.label == "Bundle path" })?.value,
              path.hasPrefix("/") else { return false }
        return AdapterSupport.canonicalPath(path) == AdapterSupport.canonicalPath(appBundle.canonicalLocation)
    }

    public static func scan(roots: [String], managerID: String = "apps") -> AppBundleScanResult {
        var rows: [Installation] = []; var partial = false; var problems: [String] = []
        for rawRoot in roots {
            guard rawRoot.hasPrefix("/") else { partial = true; problems.append("A selected Applications location was not absolute."); continue }
            let root = AdapterSupport.canonicalPath(rawRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { partial = true; problems.append("An Applications folder is unavailable: \(rawRoot)"); continue }
            do {
                var pending = [URL(fileURLWithPath: rawRoot, isDirectory: true)]
                var visited = Set<String>()
                var examined = 0
                while let directory = pending.popLast() {
                    let directoryPath = directory.standardizedFileURL.path
                    guard AdapterSupport.rootIsWithin(directoryPath, root: root), visited.insert(directoryPath).inserted else { continue }
                    examined += 1
                    if examined > 4096 { partial = true; problems.append("Applications folder traversal reached its safety limit: \(rawRoot)"); break }
                    let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                    for child in children {
                    if child.pathExtension.lowercased() == "app" {
                    let originalPath = child.standardizedFileURL.path
                    let canonical = AdapterSupport.canonicalPath(originalPath)
                    let escapesRoot = !AdapterSupport.rootIsWithin(canonical, root: root)
                    guard let info = BundleInfo.read(canonical) else { partial = true; continue }
                    let id = info.bundleIdentifier ?? "unknown-bundle-\(canonical)"
                    let receipt = FileManager.default.fileExists(atPath: canonical + "/Contents/_MASReceipt/receipt")
                    let isSystem = canonical.hasPrefix("/System/") || canonical.hasPrefix("/System/Applications/") || (info.bundleIdentifier?.hasPrefix("com.apple.") == true)
                    let isProtected = escapesRoot || isSystem
                    let reason = escapesRoot ? "The bundle resolves outside its selected Applications folder." : (isSystem ? "Apple system components are protected." : nil)
                    var evidence = [ManagerEvidence(label: "Bundle identifier", value: info.bundleIdentifier ?? "Unknown")]
                    evidence.append(ManagerEvidence(label: receipt ? "App Store receipt" : "Source", value: receipt ? "Present; distribution evidence only" : "Unknown"))
                    if escapesRoot { evidence.append(ManagerEvidence(label: "Symlink target", value: canonical)) }
                    let identity = InstallationID(managerID: managerID, scopeID: root, nativeID: id, canonicalLocation: canonical)
                    rows.append(Installation(identity: identity, kind: .appBundle, displayName: info.displayName, version: info.version, canonicalLocation: canonical, bundleIdentifier: info.bundleIdentifier, ownership: receipt ? .ambiguous : .unknown, evidence: evidence, isProtected: isProtected, protectionReason: reason))
                    } else if let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true {
                        pending.append(child)
                    }
                    }
                }
            } catch { partial = true; problems.append("Could not read Applications folder: \(rawRoot)") }
        }
        return AppBundleScanResult(installations: rows.sorted { $0.canonicalLocation < $1.canonicalLocation }, partial: partial, warning: problems.isEmpty ? nil : problems.joined(separator: " "))
    }
}

private struct BundleInfo {
    var bundleIdentifier: String?; var displayName: String; var version: String?
    static func read(_ path: String) -> BundleInfo? {
        let plistPath = path + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        guard !display.isEmpty else { return nil }
        return BundleInfo(bundleIdentifier: bundleID?.isEmpty == true ? nil : bundleID, displayName: display, version: AdapterSupport.cleanDisplay(version))
    }
}
