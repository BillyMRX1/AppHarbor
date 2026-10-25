import AppHarborCore
import Darwin
import Foundation
import XCTest
@testable import AppHarborMCPBridge

final class MCPBridgeTests: XCTestCase {
    func testIdentifiersAreDeterministicAndStrictlyValidated() throws {
        let id = InstallationID(managerID: "brew", scopeID: "/opt/homebrew", nativeID: "demo", canonicalLocation: "/opt/homebrew/Cellar/demo")
        let first = MCPInventoryPresenter.identifier(for: id)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, MCPInventoryPresenter.identifier(for: id))
        XCTAssertNoThrow(try MCPBridgeRequestValidator.validate(.init(action: .getInstallation, parameters: ["installation_id": first])))
        XCTAssertThrowsError(try MCPBridgeRequestValidator.validate(.init(action: .getInstallation, parameters: ["installation_id": "../../etc/passwd"])))
        XCTAssertThrowsError(try MCPBridgeRequestValidator.validate(.init(action: .listSources, parameters: ["unexpected": "1"])))
        XCTAssertThrowsError(try MCPBridgeRequestValidator.validate(.init(action: .listInstallations, parameters: ["limit": "101"])))
        XCTAssertThrowsError(try MCPBridgeRequestValidator.validate(.init(action: .requestRemoval, parameters: ["installation_id": first, "request_id": "not-a-uuid"])))
    }

    func testSocketPermissionsRoundTripAndDuplicateServerProtection() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let server = MCPBridgeServer(socketURL: socketURL)
        try server.start { request in
            MCPBridgeResponse(json: "{\"action\":\"\(request.action.rawValue)\"}")
        }
        defer { server.stop() }

        var socketStatus = stat()
        XCTAssertEqual(lstat(socketURL.path, &socketStatus), 0)
        XCTAssertEqual(socketStatus.st_mode & 0o777, 0o600)
        var directoryStatus = stat()
        XCTAssertEqual(lstat(socketURL.deletingLastPathComponent().path, &directoryStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & 0o777, 0o700)

        let second = MCPBridgeServer(socketURL: socketURL)
        XCTAssertThrowsError(try second.start { _ in MCPBridgeResponse(json: "{}") })

        try await withThrowingTaskGroup(of: MCPBridgeResponse.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
                }
            }
            for try await response in group {
                XCTAssertFalse(response.isError)
                XCTAssertTrue(response.json.contains("listSources"))
            }
        }
    }

    func testSymlinkedSocketDirectoryIsRejected() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = folder.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let server = MCPBridgeServer(socketURL: link.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock"))
        XCTAssertThrowsError(try server.start { _ in MCPBridgeResponse(json: "{}") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("MCP/bridge.sock").path))
    }

    func testUnsafePermissionsAndSymlinkedSocketPathAreRejected() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let unsafeDirectory = folder.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let unsafeServer = MCPBridgeServer(socketURL: unsafeDirectory.appendingPathComponent("bridge.sock"))
        XCTAssertThrowsError(try unsafeServer.start { _ in MCPBridgeResponse(json: "{}") })

        let secureDirectory = folder.appendingPathComponent("secure", isDirectory: true)
        try FileManager.default.createDirectory(at: secureDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = secureDirectory.appendingPathComponent("target")
        try Data("do not replace".utf8).write(to: target)
        let socketURL = secureDirectory.appendingPathComponent("bridge.sock")
        try FileManager.default.createSymbolicLink(at: socketURL, withDestinationURL: target)
        let server = MCPBridgeServer(socketURL: socketURL)
        XCTAssertThrowsError(try server.start { _ in MCPBridgeResponse(json: "{}") })
        let socketAttributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual(socketAttributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do not replace")
    }

    func testOversizedFrameIsRejectedBeforeHandlerRuns() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let handlerCalled = DispatchSemaphore(value: 0)
        let server = MCPBridgeServer(socketURL: socketURL, timeoutSeconds: 10)
        try server.start { _ in handlerCalled.signal(); return MCPBridgeResponse(json: "{}") }
        defer { server.stop() }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        var noSigpipe: Int32 = 1
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size)), 0)
        try setReadTimeout(fd, seconds: 3)
        let payload = Data(repeating: 65, count: 1_048_577)
        var sent = 0
        payload.withUnsafeBytes { raw in
            while sent < payload.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                sent += count
            }
        }
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !responseData.contains(10) {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { XCTFail("expected an oversize error response"); return }
            responseData.append(contentsOf: buffer.prefix(count))
        }
        let response = try JSONDecoder().decode(MCPBridgeResponse.self, from: responseData.dropLast())
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.json.contains("size limit"))
        XCTAssertEqual(handlerCalled.wait(timeout: .now()), .timedOut)
    }

    func testMalformedJSONReturnsAnErrorAndServerContinuesServing() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let handlerCalled = DispatchSemaphore(value: 0)
        let server = MCPBridgeServer(socketURL: socketURL)
        try server.start { _ in
            handlerCalled.signal()
            return MCPBridgeResponse(json: #"{"ok":true}"#)
        }
        defer { server.stop() }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        try setReadTimeout(fd, seconds: 3)
        let malformed = Data("{not-json}\n".utf8)
        let sent = malformed.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, malformed.count, 0) }
        XCTAssertEqual(sent, malformed.count)
        let response = try readBridgeResponse(from: fd)
        XCTAssertTrue(response.isError)
        let errorObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.json.utf8)) as? [String: String])
        XCTAssertNotNil(errorObject["error"])
        XCTAssertEqual(handlerCalled.wait(timeout: .now()), .timedOut)

        let validResponse = try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
        XCTAssertFalse(validResponse.isError)
        XCTAssertEqual(validResponse.json, #"{"ok":true}"#)
        XCTAssertEqual(handlerCalled.wait(timeout: .now() + 1), .success)
    }

    func testStopRestartDoesNotLetOldWorkerShutdownNewClient() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let server = MCPBridgeServer(socketURL: socketURL)
        let oldHandlerGate = AsyncHandlerGate()
        try server.start { _ in
            await oldHandlerGate.blockUntilReleased()
            return MCPBridgeResponse(json: "{\"worker\":\"old\"}")
        }

        let oldClient = Task {
            try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
        }
        let handlerEntered = await oldHandlerGate.waitUntilEntered(timeout: .seconds(5))
        XCTAssertTrue(handlerEntered, "The connected request did not reach its handler before the deadline.")
        guard handlerEntered else {
            server.stop()
            await oldHandlerGate.release()
            do {
                _ = try await oldClient.value
                XCTFail("The client unexpectedly completed before the handler was entered.")
            } catch {
                XCTFail("The client failed before its handler was entered: \(error)")
            }
            return
        }
        server.stop()
        try server.start { _ in MCPBridgeResponse(json: "{\"worker\":\"new\"}") }

        let newResponse = try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
        XCTAssertEqual(newResponse.json, "{\"worker\":\"new\"}")
        await oldHandlerGate.release()
        _ = try? await oldClient.value

        let secondNewResponse = try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
        XCTAssertEqual(secondNewResponse.json, "{\"worker\":\"new\"}")
        server.stop()
    }

    func testRapidStartStopKeepsRestartedListenerUsable() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let server = MCPBridgeServer(socketURL: socketURL)

        for _ in 0..<3 {
            try server.start { _ in MCPBridgeResponse(json: #"{"generation":"stopped"}"#) }
            server.stop()
        }

        try server.start { _ in MCPBridgeResponse(json: #"{"generation":"current"}"#) }
        let response = try await MCPBridgeClient.send(.init(action: .listSources), socketURL: socketURL)
        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.json, #"{"generation":"current"}"#)
        server.stop()
    }

    func testSlowDripCannotExtendTotalFrameDeadline() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("bridge.sock")
        let handlerCalled = DispatchSemaphore(value: 0)
        let server = MCPBridgeServer(socketURL: socketURL, timeoutSeconds: 1)
        try server.start { _ in handlerCalled.signal(); return MCPBridgeResponse(json: "{}") }
        defer { server.stop() }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        try setReadTimeout(fd, seconds: 3)
        let started = DispatchTime.now().uptimeNanoseconds
        for byte: UInt8 in [123, 34, 97] {
            _ = withUnsafePointer(to: byte) { send(fd, $0, 1, 0) }
            usleep(350_000)
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(elapsed, 2.5)
        let text = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        XCTAssertTrue(text.contains("timed out"))
        XCTAssertEqual(handlerCalled.wait(timeout: .now()), .timedOut)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let token = String(UUID().uuidString.prefix(8))
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("ah-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw MCPBridgeError.invalidSocketPath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { source in strlcpy(destination, source, capacity) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func readBridgeResponse(from fd: Int32) throws -> MCPBridgeResponse {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(MCPBridgeResponse.self, from: data.dropLast())
    }

    private actor AsyncHandlerGate {
        private var didEnter = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func blockUntilReleased() async {
            didEnter = true
            await withCheckedContinuation { continuation in releaseContinuation = continuation }
        }

        func waitUntilEntered(timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !didEnter, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return didEnter
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }
}
