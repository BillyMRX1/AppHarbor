import AppKit
import AppHarborCore
import Foundation

@MainActor
final class InstallationShortcutService {
    private let reveal: (URL) -> Void
    private let copy: (String) -> Void

    init(reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         copy: @escaping (String) -> Void = {
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString($0, forType: .string)
         }) {
        self.reveal = reveal
        self.copy = copy
    }

    func revealInFinder(_ url: URL) { reveal(url) }
    func copyPath(_ path: String) { copy(path) }
}

enum InstallationShortcutResolver {
    static func installationURL(for installation: Installation) -> Result<URL, ShortcutResolutionError> {
        let path = installation.canonicalLocation
        guard validAbsolutePath(path) else { return .failure(.changedInstallation(installation.displayName)) }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.missingInstallation(installation.canonicalLocation))
        }
        if installation.kind == .appBundle {
            guard url.pathExtension.lowercased() == "app" else {
                return .failure(.changedInstallation(installation.displayName))
            }
            let info = freshBundleInfo(at: url)
            if installation.bundleIdentifier != nil || installation.version != nil, info == nil {
                return .failure(.changedInstallation(installation.displayName))
            }
            if let expectedID = installation.bundleIdentifier,
               info?["CFBundleIdentifier"] as? String != expectedID {
                return .failure(.changedInstallation(installation.displayName))
            }
            if let expectedVersion = installation.version {
                let currentVersion = info?["CFBundleShortVersionString"] as? String
                    ?? info?["CFBundleVersion"] as? String
                guard currentVersion == expectedVersion else { return .failure(.changedInstallation(installation.displayName)) }
            }
        }
        return .success(url)
    }

    static func vendorUninstaller(for installation: Installation) -> Result<URL?, ShortcutResolutionError> {
        switch installationURL(for: installation) {
        case .failure(let error): return .failure(error)
        case .success(let appURL):
            guard installation.kind == .appBundle, appURL.pathExtension.lowercased() == "app" else { return .success(nil) }
            let root = appURL.resolvingSymlinksInPath().standardizedFileURL
            guard let evidence = installation.evidence.first(where: { $0.label == "Vendor uninstaller" }) else { return .success(nil) }
            let candidatePath = evidence.value
            guard validAbsolutePath(candidatePath) else { return .success(nil) }
            let candidate = URL(fileURLWithPath: candidatePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: candidatePath) else { return .success(nil) }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { return .success(nil) }
            if candidate.pathExtension.lowercased() == "app" {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .success(nil) }
                if let info = freshBundleInfo(at: candidate),
                   let packageType = info["CFBundlePackageType"] as? String, packageType != "APPL" { return .success(nil) }
            } else if !FileManager.default.isExecutableFile(atPath: candidate.path) {
                return .success(nil)
            }
            return .success(candidate)
        }
    }

    private static func validAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func freshBundleInfo(at appURL: URL) -> [String: Any]? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return value as? [String: Any]
    }
}

enum ShortcutResolutionError: LocalizedError, Equatable {
    case missingInstallation(String)
    case changedInstallation(String)

    var errorDescription: String? {
        switch self {
        case .missingInstallation(let path): "The installation no longer exists at \(path). Refresh the inventory and try again."
        case .changedInstallation(let name): "\(name) at this location no longer matches the reviewed app identity. Refresh the inventory before continuing."
        }
    }
}
