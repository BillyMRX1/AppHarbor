import XCTest
import Darwin
@testable import AppHarborCore

final class ProcessRunnerTests: XCTestCase {
    private let runner = FoundationProcessRunner()
    private let python = "/usr/bin/python3"

    func testNonzeroExitIsNotReportedAsTimeoutAndWorkingDirectoryIsApplied() async throws {
        let result = try await runner.run(ProcessCommand(
            executablePath: python,
            arguments: ["-c", "import os,sys; print(os.getcwd()); sys.exit(7)"],
            workingDirectory: "/tmp",
            timeout: 2
        ))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.didTimeOut)
        XCTAssertTrue(result.standardOutput.contains("/tmp"))
    }

    func testTimeoutKillsProcessThatIgnoresTerminate() async throws {
        let start = Date()
        let result = try await runner.run(ProcessCommand(
            executablePath: python,
            arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(20)"],
            timeout: 0.25
        ))
        XCTAssertTrue(result.didTimeOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testExitedLeaderStillGetsDescendantsKilledWhenPipesAreClosed() async throws {
        let readyURL = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-runner-ready-\(UUID().uuidString)")
        let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-runner-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: readyURL); try? FileManager.default.removeItem(at: pidURL) }
        let child = "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); open(sys.argv[2],'w').write('ready'); time.sleep(20)"
        let parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',\(String(reflecting: child)),sys.argv[1],sys.argv[2]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); exec('import time\\nwhile not __import__(\"os\").path.exists(sys.argv[2]): time.sleep(.01)')"
        let result = try await runner.run(ProcessCommand(executablePath: python, arguments: ["-c", parent, pidURL.path, readyURL.path], timeout: 3))
        XCTAssertEqual(result.exitCode, 0)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        let deadline = Date().addingTimeInterval(1.5)
        var alive = true
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { alive = false; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(alive, "a descendant that ignored SIGTERM must be killed before the runner returns")
    }

    func testPreCancelledRunnerDoesNotSpawnCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-runner-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try? await Task.sleep(for: .milliseconds(100))
            return try await runner.run(ProcessCommand(executablePath: python, arguments: ["-c", "open(\(String(reflecting: marker.path)),'w').write('launched')"]))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation before launch") }
        catch ProcessRunnerError.cancelledBeforeLaunch { }
        catch { XCTFail("unexpected runner error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationTerminatesRunningProcessGroup() async throws {
        let task = Task {
            try await runner.run(ProcessCommand(executablePath: python, arguments: ["-c", "import time; time.sleep(20)"], timeout: 10))
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.didTimeOut)
    }

    func testInheritedPipeFromManagerChildDoesNotHangRunner() async throws {
        let start = Date()
        let result = try await runner.run(ProcessCommand(
            executablePath: python,
            arguments: ["-c", "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)']); print('manager returned')"],
            timeout: 3
        ))
        XCTAssertTrue(result.standardOutput.contains("manager returned"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testContinuousOutputCannotStarveTimeoutChecks() async throws {
        let start = Date()
        let result = try await runner.run(ProcessCommand(
            executablePath: "/usr/bin/yes",
            arguments: [String(repeating: "x", count: 8192)],
            timeout: 0.3,
            maximumOutputBytes: 1024
        ))
        XCTAssertTrue(result.didTimeOut)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testEscapedDescendantCannotHoldPipeOpenIndefinitely() async throws {
        let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent("appharbor-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let code = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)'],start_new_session=True); open(sys.argv[1],'w').write(str(p.pid)); print('parent returned')"
        let start = Date()
        let result = try await runner.run(ProcessCommand(executablePath: python, arguments: ["-c", code, pidURL.path], timeout: 3))
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        if let pid = Int32(try String(contentsOf: pidURL, encoding: .utf8)) { _ = kill(pid, SIGKILL) }
    }

    func testOutputRetentionIsBoundedWhilePipeIsFullyDrained() async throws {
        let result = try await runner.run(ProcessCommand(
            executablePath: python,
            arguments: ["-c", "print('x' * 200000)"],
            timeout: 3,
            maximumOutputBytes: 128
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 128)
    }
}
