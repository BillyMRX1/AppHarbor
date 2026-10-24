import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public var standardOutput: String
    public var standardError: String
    public var exitCode: Int32
    public var wasCancelled: Bool
    public var didTimeOut: Bool
    public var outputWasTruncated: Bool
    public init(standardOutput: String, standardError: String, exitCode: Int32, wasCancelled: Bool = false, didTimeOut: Bool = false, outputWasTruncated: Bool = false) {
        self.standardOutput = standardOutput; self.standardError = standardError; self.exitCode = exitCode
        self.wasCancelled = wasCancelled; self.didTimeOut = didTimeOut; self.outputWasTruncated = outputWasTruncated
    }
}
public protocol ProcessRunning: Sendable { func run(_ command: ProcessCommand) async throws -> ProcessResult }
public enum ProcessRunnerError: Error, Sendable { case invalidExecutable, cancelledBeforeLaunch, launchFailed(Int32), waitFailed(Int32) }

private final class CancellationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t?
    private var cancelled = false
    func setGroup(_ pid: pid_t) {
        lock.lock(); processGroup = pid; let shouldStop = cancelled; lock.unlock()
        if shouldStop { _ = kill(-pid, SIGTERM) }
    }
    func requestCancel() {
        lock.lock(); cancelled = true; let pid = processGroup; lock.unlock()
        if let pid { _ = kill(-pid, SIGTERM) }
    }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func clearGroup() { lock.lock(); processGroup = nil; lock.unlock() }
}

/// Runs an absolute executable with argv in a private process group and without a shell.
/// Each output stream retains at most the command limit (so combined retained output is at most twice that limit),
/// is drained continuously, and is closed after a bounded post-exit grace period.
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ command: ProcessCommand) async throws -> ProcessResult {
        guard !Task.isCancelled else { throw ProcessRunnerError.cancelledBeforeLaunch }
        let envValid = command.environment.allSatisfy { key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }
        let cwdValid = command.workingDirectory.map { $0.hasPrefix("/") && !$0.contains("\0") } ?? true
        guard command.executablePath.hasPrefix("/"), !command.executablePath.contains("\0"),
              command.arguments.allSatisfy({ !$0.contains("\0") }), envValid, cwdValid,
              command.timeout > 0, command.maximumOutputBytes >= 0 else { throw ProcessRunnerError.invalidExecutable }
        let control = CancellationControl()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw ProcessRunnerError.cancelledBeforeLaunch }
            return try await Task.detached(priority: .userInitiated) { try Self.runBlocking(command, control: control) }.value
        } onCancel: { control.requestCancel() }
    }

    private static func runBlocking(_ command: ProcessCommand, control: CancellationControl) throws -> ProcessResult {
        var outFD: [Int32] = [0, 0], errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else { throw ProcessRunnerError.launchFailed(errno) }
        guard pipe(&errFD) == 0 else { closeAll(outFD); throw ProcessRunnerError.launchFailed(errno) }
        for fd in outFD + errFD { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { closeAll(outFD + errFD); throw ProcessRunnerError.launchFailed(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var actionResult = posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        if actionResult == 0 { actionResult = posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO) }
        if actionResult == 0 { actionResult = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) }
        for fd in outFD + errFD where actionResult == 0 { actionResult = posix_spawn_file_actions_addclose(&actions, fd) }
        if let directory = command.workingDirectory, actionResult == 0 {
            actionResult = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        }
        guard actionResult == 0 else { closeAll(outFD + errFD); throw ProcessRunnerError.launchFailed(actionResult) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { closeAll(outFD + errFD); throw ProcessRunnerError.launchFailed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        let attrFlags = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        let attrGroup = posix_spawnattr_setpgroup(&attributes, 0)
        guard attrFlags == 0, attrGroup == 0 else { closeAll(outFD + errFD); throw ProcessRunnerError.launchFailed(attrFlags != 0 ? attrFlags : attrGroup) }
        let argv = makeCStringVector([command.executablePath] + command.arguments)
        let envp = makeCStringVector(command.environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer { freeCStringVector(argv); freeCStringVector(envp) }
        guard !control.isCancelled() else { closeAll(outFD + errFD); throw ProcessRunnerError.cancelledBeforeLaunch }
        var pid: pid_t = 0
        let result = command.executablePath.withCString { posix_spawn(&pid, $0, &actions, &attributes, argv, envp) }
        guard result == 0 else { closeAll(outFD + errFD); throw ProcessRunnerError.launchFailed(result) }
        control.setGroup(pid)
        defer { control.clearGroup() }
        close(outFD[1]); close(errFD[1])
        _ = fcntl(outFD[0], F_SETFL, fcntl(outFD[0], F_GETFL) | O_NONBLOCK)
        _ = fcntl(errFD[0], F_SETFL, fcntl(errFD[0], F_GETFL) | O_NONBLOCK)

        let limit = command.maximumOutputBytes
        var stdout = Data(), stderr = Data(), truncated = false
        var stdoutOpen = true, stderrOpen = true, leaderExited = false
        var waitStatus: Int32 = 0
        var waitError: Int32?
        var timedOut = false
        var cleanupSent = false, killSent = false
        let start = ProcessInfo.processInfo.systemUptime
        var cleanupAt: TimeInterval?
        while !leaderExited || stdoutOpen || stderrOpen || !cleanupSent || (cleanupSent && !killSent) {
            let now = ProcessInfo.processInfo.systemUptime
            if !leaderExited && (control.isCancelled() || now - start >= command.timeout) {
                timedOut = !control.isCancelled()
                if !cleanupSent { _ = kill(-pid, SIGTERM); cleanupSent = true; cleanupAt = now + 0.2 }
            } else if leaderExited && !cleanupSent {
                // A manager-created child must not outlive its invocation or hold a pipe open forever.
                _ = kill(-pid, SIGTERM); cleanupSent = true; cleanupAt = now + 0.15
            }
            if let cleanupAt, now >= cleanupAt, !killSent { _ = kill(-pid, SIGKILL); killSent = true }

            var descriptors = [pollfd]();
            if stdoutOpen { descriptors.append(pollfd(fd: outFD[0], events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if stderrOpen { descriptors.append(pollfd(fd: errFD[0], events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if !descriptors.isEmpty { _ = poll(&descriptors, nfds_t(descriptors.count), 20) }
            else { usleep(20_000) }
            for descriptor in descriptors {
                if descriptor.fd == outFD[0], stdoutOpen { drain(fd: outFD[0], open: &stdoutOpen, target: &stdout, limit: limit, truncated: &truncated, budget: 65_536) }
                if descriptor.fd == errFD[0], stderrOpen { drain(fd: errFD[0], open: &stderrOpen, target: &stderr, limit: limit, truncated: &truncated, budget: 65_536) }
            }
            if !leaderExited {
                let waited = waitpid(pid, &waitStatus, WNOHANG)
                if waited == pid { leaderExited = true }
                else if waited < 0 && errno != EINTR { waitError = errno; leaderExited = true; _ = kill(-pid, SIGKILL) }
            }
            // A process that detached into a new group can keep inherited pipes alive; stop waiting after a short drain window.
            if leaderExited, let cleanupAt, ProcessInfo.processInfo.systemUptime >= cleanupAt + 0.75 {
                if stdoutOpen { close(outFD[0]); stdoutOpen = false; truncated = true }
                if stderrOpen { close(errFD[0]); stderrOpen = false; truncated = true }
            }
        }
        if !leaderExited { _ = waitpid(pid, &waitStatus, 0) }
        if let waitError { throw ProcessRunnerError.waitFailed(waitError) }
        return ProcessResult(standardOutput: String(decoding: stdout, as: UTF8.self), standardError: String(decoding: stderr, as: UTF8.self), exitCode: processExitCode(waitStatus), wasCancelled: control.isCancelled(), didTimeOut: timedOut, outputWasTruncated: truncated)
    }

    private static func drain(fd: Int32, open: inout Bool, target: inout Data, limit: Int, truncated: inout Bool, budget: Int) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var bytesLeft = budget
        while bytesLeft > 0 {
            let count = read(fd, &buffer, min(buffer.count, bytesLeft))
            if count > 0 {
                let amount = Int(count), remaining = max(0, limit - target.count)
                bytesLeft -= amount
                if remaining > 0 { target.append(contentsOf: buffer.prefix(min(amount, remaining))) }
                if amount > remaining { truncated = true }
            } else if count == 0 { close(fd); open = false; return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else { close(fd); open = false; return }
        }
    }
    private static func processExitCode(_ status: Int32) -> Int32 { status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
    private static func closeAll(_ descriptors: [Int32]) { for fd in descriptors { close(fd) } }
    private static func makeCStringVector(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let vector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { vector[index] = strdup(string) }
        vector[strings.count] = nil; return vector
    }
    private static func freeCStringVector(_ vector: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0; while let pointer = vector[index] { free(pointer); index += 1 }; vector.deallocate()
    }
}
