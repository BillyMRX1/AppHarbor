import AppHarborCore
import Foundation
import XCTest
@testable import AppHarbor

@MainActor
final class InstallationShortcutsTests: XCTestCase {
    func testReviewShortcutUsesCapturedInstallationAfterSelectionChanges() throws {
        let fixture = try makeAppFixture(name: "Reviewed.app", bundleID: "test.reviewed", version: "1")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var revealed: URL?
        let model = LibraryModel()
        model.shortcutService = InstallationShortcutService(reveal: { revealed = $0 }, copy: { _ in })
        model.reviewInstallation = fixture.installation
        model.selection = [InstallationID(managerID: "other", scopeID: "other", nativeID: "other", canonicalLocation: "/tmp/other.app")]

        model.showReviewedInstallationInFinder()

        XCTAssertEqual(revealed?.path, fixture.app.path)
        XCTAssertNil(model.shortcutMessage)
    }

    func testLateDismissalDoesNotClearNewerReviewContext() {
        let oldInstallation = InstallationShortcutResolverTestsFixture.missingInstallation()
        var newInstallation = oldInstallation
        newInstallation.identity = InstallationID(managerID: "new", scopeID: "/new", nativeID: "new.app", canonicalLocation: "/tmp/new.app")
        newInstallation.canonicalLocation = newInstallation.identity.canonicalLocation
        let model = LibraryModel()
        model.reviewInstallation = oldInstallation
        model.reviewContextToken = UUID()
        model.planDecision = .blocked(reason: "old review")
        model.planDecisionSheetDidPresent()
        model.planDecision = nil

        model.reviewInstallation = newInstallation
        model.reviewContextToken = UUID()
        model.planDecision = .blocked(reason: "new review")
        model.planDecisionSheetDidDismiss()

        XCTAssertEqual(model.reviewInstallation?.identity, newInstallation.identity)
    }

    func testMissingInstallationReportsRefreshGuidanceWithoutRevealing() {
        var revealCount = 0
        let model = LibraryModel()
        model.shortcutService = InstallationShortcutService(reveal: { _ in revealCount += 1 }, copy: { _ in })
        model.reviewInstallation = InstallationShortcutResolverTestsFixture.missingInstallation()

        model.showReviewedInstallationInFinder()

        XCTAssertEqual(revealCount, 0)
        XCTAssertTrue(model.shortcutMessage?.contains("no longer exists") == true)
        XCTAssertTrue(model.shortcutMessage?.contains("Refresh the inventory") == true)
    }

    func testShowFinderReadsFreshBundleIdentityAfterSamePathReplacement() throws {
        let fixture = try makeAppFixture(name: "Swapped.app", bundleID: "test.original", version: "1")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeBundleInfo(at: fixture.app, bundleID: "test.replacement", version: "1")
        var revealCount = 0
        let model = LibraryModel()
        model.shortcutService = InstallationShortcutService(reveal: { _ in revealCount += 1 }, copy: { _ in })
        model.reviewInstallation = fixture.installation

        model.showReviewedInstallationInFinder()

        XCTAssertEqual(revealCount, 0)
        XCTAssertTrue(model.shortcutMessage?.contains("no longer matches") == true)
    }

    func testShowFinderAllowsFreshBundleInfoWithoutOptionalPackageType() throws {
        let fixture = try makeAppFixture(name: "OptionalType.app", bundleID: "test.optional", version: "3")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.optional",
                                                                         "CFBundleVersion": "3",
                                                                         "CFBundleShortVersionString": "3"],
                                                       format: .xml, options: 0)
        try plist.write(to: fixture.app.appendingPathComponent("Contents/Info.plist"))
        var revealed: URL?
        let model = LibraryModel()
        model.shortcutService = InstallationShortcutService(reveal: { revealed = $0 }, copy: { _ in })
        model.reviewInstallation = fixture.installation

        model.showReviewedInstallationInFinder()

        XCTAssertEqual(revealed?.path, fixture.app.path)
    }

    func testVendorUninstallerMustStillExistAndIsOnlyRevealed() throws {
        let fixture = try makeAppFixture(name: "Vendor.app", bundleID: "test.vendor", version: "2")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let uninstaller = helpers.appendingPathComponent("Uninstaller.app", isDirectory: true)
        try FileManager.default.createDirectory(at: uninstaller, withIntermediateDirectories: true)
        let installation = withVendorEvidence(fixture.installation, path: uninstaller.path)
        guard case .success(let found?) = InstallationShortcutResolver.vendorUninstaller(for: installation) else {
            return XCTFail("An existing, contained vendor uninstaller should be detected.")
        }
        XCTAssertEqual(found.path, uninstaller.path)

        try FileManager.default.removeItem(at: uninstaller)
        var revealed: [URL] = []
        let model = LibraryModel()
        model.shortcutService = InstallationShortcutService(reveal: { revealed.append($0) }, copy: { _ in })
        model.reviewInstallation = installation
        model.showReviewedUninstallerInFinder()

        XCTAssertTrue(revealed.isEmpty, "Removing an uninstaller after detection must not reveal a stale or substitute target.")
        XCTAssertTrue(model.shortcutMessage?.contains("No existing vendor uninstaller") == true)
    }

    func testVendorUninstallerSymlinkCannotEscapeAppBundle() throws {
        let fixture = try makeAppFixture(name: "Escaping.app", bundleID: "test.escaping", version: "1")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("Uninstaller")
        try Data("not executable".utf8).write(to: outside)
        let helperDirectory = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let escaped = helperDirectory.appendingPathComponent("Uninstaller")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
        let installation = withVendorEvidence(fixture.installation, path: escaped.path)

        guard case .success(let target) = InstallationShortcutResolver.vendorUninstaller(for: installation) else {
            return XCTFail("A symlink escape should be ignored, not reported as an error.")
        }
        XCTAssertNil(target)
    }

    func testRemovedEvidencePathDoesNotFallBackToAnotherVendorCandidate() throws {
        let fixture = try makeAppFixture(name: "Multiple.app", bundleID: "test.multiple", version: "1")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resources = fixture.app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let stale = resources.appendingPathComponent("Uninstaller.app", isDirectory: true)
        let second = resources.appendingPathComponent("AnotherUninstaller.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let installation = withVendorEvidence(fixture.installation, path: stale.path)
        try FileManager.default.removeItem(at: stale)

        guard case .success(let target) = InstallationShortcutResolver.vendorUninstaller(for: installation) else {
            return XCTFail("A stale adapter evidence path should be unavailable, without rescanning for a substitute.")
        }
        XCTAssertNil(target)
    }

    private func makeAppFixture(name: String, bundleID: String, version: String) throws -> (root: URL, app: URL, installation: Installation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppHarborShortcuts-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL", "CFBundleVersion": version,
                                  "CFBundleShortVersionString": version]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let identity = InstallationID(managerID: "app-bundles", scopeID: root.path, nativeID: bundleID, canonicalLocation: app.path)
        let installation = Installation(identity: identity, kind: .appBundle, displayName: name, version: version,
                                        canonicalLocation: app.path, bundleIdentifier: bundleID, ownership: .verified)
        return (root, app, installation)
    }

    private func withVendorEvidence(_ installation: Installation, path: String) -> Installation {
        var copy = installation
        copy.evidence.append(ManagerEvidence(label: "Vendor uninstaller", value: path))
        return copy
    }

    private func writeBundleInfo(at app: URL, bundleID: String, version: String) throws {
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL", "CFBundleVersion": version,
                                  "CFBundleShortVersionString": version]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}

private enum InstallationShortcutResolverTestsFixture {
    static func missingInstallation() -> Installation {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("AppHarbor-missing-\(UUID().uuidString).app").path
        let identity = InstallationID(managerID: "app-bundles", scopeID: "/Applications", nativeID: "test.missing", canonicalLocation: path)
        return Installation(identity: identity, kind: .appBundle, displayName: "Missing", version: "1", canonicalLocation: path,
                            bundleIdentifier: "test.missing", ownership: .verified)
    }
}
