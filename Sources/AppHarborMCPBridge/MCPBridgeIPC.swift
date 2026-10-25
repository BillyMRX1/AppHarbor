import Darwin
import Foundation

private let bridgeMaximumMessageBytes = 1_048_576
private let bridgeMaximumClients = 8
private let bridgeTimeoutSeconds: Int = 30

public final class MCPBridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (MCPBridgeRequest) async -> MCPBridgeResponse

    private let socketURL: URL
    private let timeoutSeconds: Int
    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.appharbor.mcp-bridge.io", qos: .userInitiated, attributes: .concurrent)
    private var listenerFD: Int32 = -1
    private var generation: UInt64 = 0
    private var lockFD: Int32 = -1
    private var activeFDs: Set<Int32> = []
    private var handler: Handler?
    private var socketDevice: dev_t?
    private var socketInode: ino_t?

    public static var defaultSocketURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("AppHarbor", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("bridge.sock", isDirectory: false)
    }

    public convenience init() { self.init(socketURL: Self.defaultSocketURL, timeoutSeconds: bridgeTimeoutSeconds) }

    /// Test-only path injection. Production callers should use `init()`.
    init(socketURL: URL, timeoutSeconds: Int = bridgeTimeoutSeconds) {
        self.socketURL = socketURL
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    public func start(handler: @escaping Handler) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listenerFD < 0 else { throw MCPBridgeError.alreadyStarted }

        let path = socketURL.path
        try Self.prepareSocketDirectory(for: path)
        let lockPath = path + ".lock"
        let openedLock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard openedLock >= 0 else { throw MCPBridgeError.unsafePath(lockPath) }
        var lockStatus = stat()
        guard fstat(openedLock, &lockStatus) == 0,
              lockStatus.st_uid == geteuid(),
              (lockStatus.st_mode & S_IFMT) == S_IFREG,
              lockStatus.st_mode & 0o077 == 0,
              flock(openedLock, LOCK_EX | LOCK_NB) == 0 else {
            close(openedLock)
            throw MCPBridgeError.socketUnavailable("another AppHarbor instance may already own the bridge")
        }
        lockFD = openedLock

        do {
            try Self.removeSafeStaleSocket(at: path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.posixError("create socket") }
            do {
                try Self.configureSocket(fd)
                var address = try Self.socketAddress(path)
                let bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bindResult == 0 else { throw Self.posixError("bind socket") }
                guard chmod(path, mode_t(0o600)) == 0 else { throw Self.posixError("secure socket") }
                try Self.setNonBlocking(fd)
                guard listen(fd, Int32(bridgeMaximumClients)) == 0 else { throw Self.posixError("listen") }
                var socketStatus = stat()
                guard lstat(path, &socketStatus) == 0,
                      (socketStatus.st_mode & S_IFMT) == S_IFSOCK,
                      socketStatus.st_uid == geteuid(),
                      socketStatus.st_mode & 0o777 == 0o600 else {
                    throw MCPBridgeError.unsafePath(path)
                }
                listenerFD = fd
                generation &+= 1
                let serverGeneration = generation
                self.handler = handler
                socketDevice = socketStatus.st_dev
                socketInode = socketStatus.st_ino
                ioQueue.async { [weak self] in
                    guard let self else { close(fd); return }
                    self.acceptLoop(listener: fd, generation: serverGeneration)
                }
            } catch {
                close(fd)
                throw error
            }
        } catch {
            close(lockFD)
            lockFD = -1
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        let listener = listenerFD
        if listener >= 0 { _ = shutdown(listener, SHUT_RDWR) }
        for fd in activeFDs { shutdown(fd, SHUT_RDWR) }
        listenerFD = -1
        generation &+= 1
        handler = nil
        let lock = lockFD
        lockFD = -1
        let device = socketDevice
        let inode = socketInode
        socketDevice = nil
        socketInode = nil
        stateLock.unlock()

        // Accept loops and connection workers own their descriptors and close each exactly once.
        if let device, let inode { Self.unlinkOwnedSocket(at: socketURL.path, device: device, inode: inode) }
        if lock >= 0 { close(lock) }
    }

    deinit { stop() }

    private func acceptLoop(listener: Int32, generation expectedGeneration: UInt64) {
        defer {
            stateLock.lock()
            if listenerFD == listener && generation == expectedGeneration { listenerFD = -1 }
            close(listener)
            stateLock.unlock()
        }
        while isCurrent(listener, generation: expectedGeneration) {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listener, $0, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                if !isCurrent(listener, generation: expectedGeneration) { return }
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(100_000) }
                else { usleep(20_000) }
                continue
            }
            do {
                try Self.configureAcceptedSocket(client)
                try Self.verifyPeerUser(client)
            } catch {
                close(client)
                continue
            }
            stateLock.lock()
            let allowed = listenerFD == listener && generation == expectedGeneration && activeFDs.count < bridgeMaximumClients
            if allowed { activeFDs.insert(client) }
            stateLock.unlock()
            guard allowed else { close(client); continue }
            ioQueue.async { [weak self] in
                guard let self else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    return
                }
                self.serve(client, generation: expectedGeneration)
            }
        }
    }

    private func isCurrent(_ listener: Int32, generation expectedGeneration: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenerFD == listener && generation == expectedGeneration
    }

    private func serve(_ fd: Int32, generation expectedGeneration: UInt64) {
        defer {
            stateLock.lock()
            activeFDs.remove(fd)
            shutdown(fd, SHUT_RDWR)
            close(fd)
            stateLock.unlock()
        }
        do {
            try Self.setTimeouts(fd, seconds: timeoutSeconds)
            let line = try Self.readFrame(fd, timeoutSeconds: timeoutSeconds)
            let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: line)
            try MCPBridgeRequestValidator.validate(request)
            stateLock.lock()
            let action = generation == expectedGeneration ? handler : nil
            stateLock.unlock()
            guard let action else { throw MCPBridgeError.socketUnavailable("bridge stopped") }
            let semaphore = DispatchSemaphore(value: 0)
            let resultBox = ResponseBox()
            Task.detached {
                resultBox.set(await action(request))
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success,
                  let response = resultBox.get() else { throw MCPBridgeError.timedOut }
            try Self.writeFrame(response, to: fd)
        } catch {
            let response = MCPBridgeResponse(json: Self.errorJSON(error), isError: true)
            try? Self.writeFrame(response, to: fd)
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: MCPBridgeResponse?
        func set(_ value: MCPBridgeResponse) { lock.lock(); response = value; lock.unlock() }
        func get() -> MCPBridgeResponse? { lock.lock(); defer { lock.unlock() }; return response }
    }

    private static func errorJSON(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let data = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys, .fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"AppHarbor bridge error\"}"
    }

    private static func prepareSocketDirectory(for socketPath: String, createMissing: Bool = true) throws {
        let separator = socketPath.lastIndex(of: "/")
        let directory = separator.map { $0 == socketPath.startIndex ? "/" : String(socketPath[..<$0]) } ?? "."
        var current = "/"
        let components = directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (index, component) in components.enumerated() {
            current = current == "/" ? current + component : current + "/" + component
            var status = stat()
            if lstat(current, &status) != 0 {
                guard errno == ENOENT else { throw MCPBridgeError.unsafePath(current) }
                guard createMissing else { throw MCPBridgeError.socketUnavailable("Open AppHarbor to start its local bridge") }
                guard mkdir(current, mode_t(0o700)) == 0 else { throw MCPBridgeError.unsafePath(current) }
                guard lstat(current, &status) == 0 else { throw MCPBridgeError.unsafePath(current) }
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == 0 || status.st_uid == geteuid() else { throw MCPBridgeError.unsafePath(current) }
            let isPrivateLeaf = index >= components.count - 2
            if isPrivateLeaf {
                guard status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw MCPBridgeError.unsafePath(current) }
            } else if status.st_mode & 0o022 != 0 && !(status.st_uid == 0 && status.st_mode & S_ISVTX != 0) {
                throw MCPBridgeError.unsafePath(current)
            }
        }
    }

    private static func removeSafeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw MCPBridgeError.unsafePath(path)
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              unlink(path) == 0 else { throw MCPBridgeError.unsafePath(path) }
    }

    private static func unlinkOwnedSocket(at path: String, device: dev_t, inode: ino_t) {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_uid == geteuid(), status.st_dev == device, status.st_ino == inode else { return }
        _ = unlink(path)
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MCPBridgeError.invalidSocketPath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { source in strlcpy(destination, source, capacity) }
            }
        }
        return address
    }

    private static func verifyPeerUser(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw MCPBridgeError.peerIdentityMismatch }
    }

    private static func configureSocket(_ fd: Int32) throws {
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw posixError("mark socket close-on-exec")
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw posixError("configure socket") }
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixError("configure nonblocking listener")
        }
    }

    private static func configureAcceptedSocket(_ fd: Int32) throws {
        try configureSocket(fd)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw posixError("configure blocking client socket")
        }
    }

    private static func setTimeouts(_ fd: Int32, seconds: Int = bridgeTimeoutSeconds) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw posixError("configure timeout") }
    }

    private static func readFrame(_ fd: Int32, timeoutSeconds: Int = bridgeTimeoutSeconds) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var data = Data()
        let duration = UInt64(timeoutSeconds) * 1_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds &+ duration
        while data.count <= bridgeMaximumMessageBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw MCPBridgeError.timedOut }
            let remaining = deadline - now
            var timeout = timeval(tv_sec: Int(remaining / 1_000_000_000), tv_usec: Int32((remaining % 1_000_000_000) / 1_000))
            if timeout.tv_sec == 0 && timeout.tv_usec == 0 { timeout.tv_usec = 1 }
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw posixError("configure read deadline") }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { throw MCPBridgeError.malformedMessage }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw MCPBridgeError.timedOut }
                throw posixError("read socket")
            }
            let chunk = Data(buffer.prefix(count))
            if let newline = chunk.firstIndex(of: 10) {
                data.append(chunk[..<newline])
                guard data.count <= bridgeMaximumMessageBytes,
                      chunk.index(after: newline) == chunk.endIndex else { throw MCPBridgeError.malformedMessage }
                return data
            }
            data.append(chunk)
        }
        throw MCPBridgeError.messageTooLarge
    }

    private static func writeFrame(_ response: MCPBridgeResponse, to fd: Int32) throws {
        var data = try JSONEncoder().encode(response)
        guard data.count <= bridgeMaximumMessageBytes else { throw MCPBridgeError.messageTooLarge }
        data.append(10)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if written < 0 {
                if errno == EINTR { continue }
                throw posixError("write socket")
            }
            guard written > 0 else { throw MCPBridgeError.socketUnavailable("write socket: connection closed") }
            offset += written
        }
    }

    private static func posixError(_ operation: String) -> Error {
        MCPBridgeError.socketUnavailable("\(operation): \(String(cString: strerror(errno)))")
    }
}

public enum MCPBridgeClient {
    private static let ioQueue = DispatchQueue(label: "com.appharbor.mcp-bridge.client-io", qos: .userInitiated, attributes: .concurrent)

    public static func send(_ request: MCPBridgeRequest) async throws -> MCPBridgeResponse {
        try MCPBridgeRequestValidator.validate(request)
        return try await send(request, socketURL: MCPBridgeServer.defaultSocketURL)
    }

    static func send(_ request: MCPBridgeRequest, socketURL: URL) async throws -> MCPBridgeResponse {
        try MCPBridgeRequestValidator.validate(request)
        let path = socketURL.path
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do { continuation.resume(returning: try sendSynchronously(request, path: path)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func sendSynchronously(_ request: MCPBridgeRequest, path: String) throws -> MCPBridgeResponse {
        try MCPBridgeServer.prepareClientPath(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPBridgeError.socketUnavailable("could not create the local connection") }
        defer { close(fd) }
        try MCPBridgeServer.disableClientSIGPIPE(fd)
        try MCPBridgeServer.setClientTimeouts(fd)
        var address = try MCPBridgeServer.makeClientAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw MCPBridgeError.socketUnavailable(String(cString: strerror(errno))) }
        try MCPBridgeServer.verifyClientPeer(fd)
        try MCPBridgeServer.sendClientFrame(request, to: fd)
        return try MCPBridgeServer.receiveClientFrame(from: fd)
    }
}

private extension MCPBridgeServer {
    static func prepareClientPath(_ path: String) throws {
        try prepareSocketDirectory(for: path, createMissing: false)
        let separator = path.lastIndex(of: "/")
        let directory = separator.map { $0 == path.startIndex ? "/" : String(path[..<$0]) } ?? "."
        var status = stat()
        guard lstat(directory, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw MCPBridgeError.unsafePath(directory) }
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o600 else { throw MCPBridgeError.socketUnavailable("Open AppHarbor to start its local bridge") }
    }
    static func disableClientSIGPIPE(_ fd: Int32) throws { try configureSocket(fd) }
    static func setClientTimeouts(_ fd: Int32) throws { try setTimeouts(fd) }
    static func makeClientAddress(_ path: String) throws -> sockaddr_un { try socketAddress(path) }
    static func verifyClientPeer(_ fd: Int32) throws { try verifyPeerUser(fd) }
    static func sendClientFrame(_ request: MCPBridgeRequest, to fd: Int32) throws {
        var data = try JSONEncoder().encode(request)
        guard data.count <= bridgeMaximumMessageBytes else { throw MCPBridgeError.messageTooLarge }
        data.append(10)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if written < 0 { if errno == EINTR { continue }; throw posixError("write socket") }
            guard written > 0 else { throw MCPBridgeError.socketUnavailable("write socket: connection closed") }
            offset += written
        }
    }
    static func receiveClientFrame(from fd: Int32) throws -> MCPBridgeResponse {
        let data = try readFrame(fd)
        return try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
    }
}
