import Foundation
import AppKit
import Darwin
import CryptoKit

/// The reviewed identity of one ordinary app bundle. Device and inode prevent a replaced path
/// from inheriting an earlier approval; the fingerprint hashes fresh raw Info.plist bytes.
public struct AppBundleTrashTarget: Codable, Hashable, Sendable {
    public var appPath: String
    public var scopeRoot: String
    public var device: UInt64
    public var inode: UInt64
    public var bundleIdentifier: String
    public var metadataFingerprint: String

    public init(appPath: String, scopeRoot: String, device: UInt64, inode: UInt64, bundleIdentifier: String, metadataFingerprint: String) {
        self.appPath = appPath; self.scopeRoot = scopeRoot; self.device = device; self.inode = inode
        self.bundleIdentifier = bundleIdentifier; self.metadataFingerprint = metadataFingerprint
    }

    public static func capture(path: String, scopeRoot: String, bundleIdentifier: String? = nil) -> AppBundleTrashTarget? {
        guard let identity = NativeAppTrash.identity(path: path, scopeRoot: scopeRoot),
              let metadata = NativeAppTrash.readMetadata(path: identity.path),
              bundleIdentifier == nil || bundleIdentifier == metadata.bundleIdentifier else { return nil }
        let identifier = metadata.bundleIdentifier
        let fingerprint = NativeAppTrash.fingerprint(bundleIdentifier: identifier, infoPlistData: metadata.data)
        return AppBundleTrashTarget(appPath: identity.path, scopeRoot: identity.scope, device: identity.device, inode: identity.inode, bundleIdentifier: identifier, metadataFingerprint: fingerprint)
    }
}

public struct NativeAppTrashResult: Sendable {
    public var originalPathIsAbsent: Bool
    public var trashedPath: String
    public var hasExpectedIdentity: Bool
    public init(originalPathIsAbsent: Bool, trashedPath: String, hasExpectedIdentity: Bool) {
        self.originalPathIsAbsent = originalPathIsAbsent; self.trashedPath = trashedPath; self.hasExpectedIdentity = hasExpectedIdentity
    }
    public var isVerified: Bool { originalPathIsAbsent && hasExpectedIdentity }
}

public protocol NativeAppTrashExecuting: Sendable {
    func trash(_ target: AppBundleTrashTarget) throws -> NativeAppTrashResult
}

public enum NativeAppTrashError: Error, Equatable, Sendable {
    case invalidTarget
    case changedTarget
    case protectedTarget
    case runningTarget
    case permissionDenied
    case trashVerificationFailed
}

public struct FileManagerAppTrashExecutor: NativeAppTrashExecuting {
    public init() {}
    public func trash(_ target: AppBundleTrashTarget) throws -> NativeAppTrashResult {
        guard NativeAppTrash.isValid(target) else { throw NativeAppTrashError.invalidTarget }
        guard NativeAppTrash.fingerprintMatches(target) else { throw NativeAppTrashError.changedTarget }
        guard !NativeAppTrash.isProtected(target) else { throw NativeAppTrashError.protectedTarget }
        guard !NativeAppTrash.isRunning(target) else { throw NativeAppTrashError.runningTarget }
        guard NativeAppTrash.isWritable(target) else { throw NativeAppTrashError.permissionDenied }

        let originalURL = URL(fileURLWithPath: target.appPath, isDirectory: true)
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: originalURL, resultingItemURL: &trashedURL)
        guard let destination = trashedURL as URL? else { throw NativeAppTrashError.trashVerificationFailed }
        let absent = !FileManager.default.fileExists(atPath: target.appPath)
        let identityMatches = NativeAppTrash.matchesIdentity(path: destination.path, target: target)
        return NativeAppTrashResult(originalPathIsAbsent: absent, trashedPath: destination.path, hasExpectedIdentity: identityMatches)
    }
}

enum NativeAppTrash {
    struct Identity { var path: String; var scope: String; var device: UInt64; var inode: UInt64 }

    static func identity(path: String, scopeRoot: String) -> Identity? {
        guard let appPath = lexicalAbsolutePath(path), let rootPath = lexicalAbsolutePath(scopeRoot),
              let appURL = Optional(URL(fileURLWithPath: appPath)),
              URL(fileURLWithPath: appPath).pathExtension == "app",
              URL(fileURLWithPath: appPath).deletingLastPathComponent().path == rootPath,
              !appPath.hasPrefix("/System/"), appPath != "/System",
              safeApplicationRoot(rootPath),
              hasOnlyRealDirectoryComponents(rootPath),
              let values = try? appURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage == true,
              let stat = lstatPath(appPath), (stat.st_mode & S_IFMT) == S_IFDIR,
              let rootStat = lstatPath(rootPath), (rootStat.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Identity(path: appPath, scope: rootPath, device: UInt64(stat.st_dev), inode: UInt64(stat.st_ino))
    }

    struct BundleMetadata {
        var bundleIdentifier: String
        var data: Data
    }

    static func readMetadata(path: String) -> BundleMetadata? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let object = plist as? [String: Any],
              let identifier = object["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return BundleMetadata(bundleIdentifier: identifier, data: data)
    }

    static func fingerprint(bundleIdentifier: String, infoPlistData: Data) -> String {
        let digest = SHA256.hash(data: infoPlistData).map { String(format: "%02x", $0) }.joined()
        return "\(bundleIdentifier):\(digest)"
    }

    static func fingerprintMatches(_ target: AppBundleTrashTarget) -> Bool {
        guard let fresh = AppBundleTrashTarget.capture(path: target.appPath, scopeRoot: target.scopeRoot, bundleIdentifier: target.bundleIdentifier) else { return false }
        return fresh == target
    }

    static func matchesIdentity(path: String, target: AppBundleTrashTarget) -> Bool {
        guard let stat = lstatPath(path), (stat.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard UInt64(stat.st_dev) == target.device, UInt64(stat.st_ino) == target.inode,
              let metadata = readMetadata(path: path) else { return false }
        return metadata.bundleIdentifier == target.bundleIdentifier
            && fingerprint(bundleIdentifier: metadata.bundleIdentifier, infoPlistData: metadata.data) == target.metadataFingerprint
    }

    static func isValid(_ target: AppBundleTrashTarget) -> Bool {
        guard let identity = identity(path: target.appPath, scopeRoot: target.scopeRoot) else { return false }
        return identity.path == target.appPath && identity.scope == target.scopeRoot && identity.device == target.device && identity.inode == target.inode
    }

    static func isWritable(_ target: AppBundleTrashTarget) -> Bool {
        let parent = URL(fileURLWithPath: target.appPath).deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: target.scopeRoot)
    }

    private static func safeApplicationRoot(_ path: String) -> Bool {
        let blockedComponents: Set<String> = ["System", "usr", "bin", "sbin", "Library", "Caskroom", "Cellar", ".Trash", ".Trashes", "Trash"]
        let components = path.split(separator: "/").map(String.init)
        guard path != "/", !components.contains(where: { blockedComponents.contains($0) }),
              !components.contains(where: { $0.hasSuffix(".app") }) else { return false }
        let home = "/" + NSHomeDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let managerRoots = ["/opt/homebrew", "/usr/local", "/usr", "/bin", "/sbin"]
        return path != home && !path.hasPrefix(home + "/Library") && !managerRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    private static func hasOnlyRealDirectoryComponents(_ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            guard let value = lstatPath(prefix), (value.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }

    static func isProtected(_ target: AppBundleTrashTarget) -> Bool {
        let id = target.bundleIdentifier.lowercased()
        if id.hasPrefix("com.apple.") || id == "com.appharbor.desktop" || id == Bundle.main.bundleIdentifier?.lowercased() { return true }
        let path = target.appPath
        let appBundle = Bundle.main.bundleURL.standardizedFileURL.path
        let appExecutable = Bundle.main.executableURL?.standardizedFileURL.path
        let isAppHarbor = [appBundle, appExecutable].compactMap { $0 }.contains { candidate in
            path == candidate || candidate.hasPrefix(path + "/") || path.hasPrefix(candidate + "/")
        }
        return isAppHarbor || path == "/System" || path.hasPrefix("/System/")
    }

    static func isRunning(_ target: AppBundleTrashTarget) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleURL = app.bundleURL else { return false }
            return bundleURL.standardizedFileURL.path == target.appPath
        }
    }

    private static func lexicalAbsolutePath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains("\0") else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("."), !components.contains("..") else { return nil }
        let normalized = "/" + components.joined(separator: "/")
        return normalized
    }

    private static func lstatPath(_ path: String) -> Darwin.stat? {
        var value = Darwin.stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { return nil }
        return value
    }
}
