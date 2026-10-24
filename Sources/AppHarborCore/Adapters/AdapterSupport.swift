import Foundation
import CryptoKit

public enum AdapterSupport {
    static let outputLimit = 2_000_000
    static let readTimeout: TimeInterval = 20

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func executableExists(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalPath(path)),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let current = getuid()
        return (owner == 0 || owner == current) && (permissions & 0o022 == 0)
    }

    static func executableFingerprint(_ path: String) -> String {
        let canonical = canonicalPath(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical) else { return "missing:\(canonical)" }
        let size = (attributes[.size] as? NSNumber)?.stringValue ?? "?"
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.description ?? "?"
        let digest = (try? Data(contentsOf: URL(fileURLWithPath: canonical), options: [.mappedIfSafe])).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unreadable"
        return "\(canonical)|\(size)|\(modified)|\(digest)"
    }

    static func fingerprint(_ pieces: [String?]) -> String {
        pieces.compactMap { $0 }.joined(separator: "\u{1f}")
    }

    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.range(of: "^[A-Za-z0-9_./:@%+=,-]+$", options: .regularExpression) != nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func renderPreview(_ command: ProcessCommand) -> String {
        let environment = command.environment.keys.sorted().compactMap { key -> String? in
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  let value = command.environment[key] else { return nil }
            return "\(key)=\(shellQuote(value))"
        }
        let invocation = (["env"] + environment + [shellQuote(command.executablePath)] + command.arguments.map(shellQuote)).joined(separator: " ")
        if let directory = command.workingDirectory { return "cd \(shellQuote(directory)) && \(invocation)" }
        return invocation
    }

    static func process(_ executable: String, _ arguments: [String], environment: [String: String] = [:], cwd: String? = nil, timeout: TimeInterval = readTimeout) -> ProcessCommand {
        ProcessCommand(executablePath: URL(fileURLWithPath: executable).standardizedFileURL.path, arguments: arguments, environment: baseEnvironment(executables: [executable], additional: environment), workingDirectory: cwd, timeout: timeout, maximumOutputBytes: outputLimit)
    }

    static func baseEnvironment(executables: [String], additional: [String: String] = [:]) -> [String: String] {
        let pathDirs = executables.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        var environment = ["HOME": NSHomeDirectory(), "PATH": (pathDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"), "LANG": "C", "LC_ALL": "C"]
        if let temp = ProcessInfo.processInfo.environment["TMPDIR"], temp.hasPrefix("/"), temp.count < 512 { environment["TMPDIR"] = temp }
        for (key, value) in additional { environment[key] = value }
        return environment
    }

    static func run(_ runner: any ProcessRunning, executable: String, arguments: [String], environment: [String: String] = [:], cwd: String? = nil, timeout: TimeInterval = readTimeout) async -> ProcessResult? {
        guard executableExists(executable) else { return nil }
        do { return try await runner.run(process(executable, arguments, environment: environment, cwd: cwd, timeout: timeout)) }
        catch { return nil }
    }

    static func candidateExecutables(named name: String, known: [String], explicit: [String]) -> [String] {
        var seen = Set<String>()
        return (explicit + known).compactMap { path in
            guard path.hasPrefix("/"), executableExists(path) else { return nil }
            let canonical = canonicalPath(path)
            guard seen.insert(canonical).inserted else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }

    static func parsedJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func cleanDisplay(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 512, !value.contains("\n"), !value.contains("\r") else { return nil }
        return value
    }

    static func semverMajor(_ value: String?) -> Int? {
        guard let value, let match = value.range(of: #"(?<![0-9])[0-9]+(?=\.)"#, options: .regularExpression) else { return nil }
        return Int(value[match])
    }

    static func isSafeNativeID(_ value: String, allowed: String) -> Bool {
        !value.isEmpty && value.count < 256 && value.range(of: "^\(allowed)$", options: .regularExpression) != nil && !value.hasPrefix("-")
    }

    static func commandSucceeded(_ result: ProcessResult?) -> Bool {
        guard let result else { return false }
        return result.exitCode == 0 && !result.didTimeOut && !result.wasCancelled && !result.outputWasTruncated
    }

    static func rootIsWithin(_ path: String, root: String) -> Bool {
        let p = canonicalPath(path), r = canonicalPath(root)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    static func unsupportedGuidance(_ name: String, reason: String, command: String? = nil, url: String? = nil) -> PlanDecision {
        .guidance(RemovalGuidance(title: "Manage \(name) manually", steps: [reason, "Review the owning manager's documentation and verify the selected installation before making changes."], displayCommand: command, sourceURL: url.flatMap(URL.init(string:)), isVerified: false), reason: reason)
    }
}
