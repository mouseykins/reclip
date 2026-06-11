import XCTest
@testable import Reclip

final class ProcessRunnerTests: XCTestCase {

    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    func testCapturesStdoutStderrAndExitStatus() async throws {
        let result = try await runProcess(shell("echo out; echo err 1>&2; exit 3"))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(result.stderr, "err\n")
    }

    func testStreamsLineCallbacks() async throws {
        let lock = NSLock()
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        let result = try await runProcess(
            shell("echo one; echo two; echo three 1>&2"),
            onStdoutLine: { line in lock.lock(); stdoutLines.append(line); lock.unlock() },
            onStderrLine: { line in lock.lock(); stderrLines.append(line); lock.unlock() }
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(stdoutLines, ["one", "two"])
        XCTAssertEqual(stderrLines, ["three"])
    }

    func testLargeStderrDoesNotDeadlock() async throws {
        // Regression for the fetchInfo hang: >64KB written to stderr while
        // stdout stays open must not stall the child on a full pipe buffer.
        let filler = String(repeating: "x", count: 64)
        let result = try await runProcess(
            shell("i=0; while [ $i -lt 2000 ]; do echo \(filler) 1>&2; i=$((i+1)); done; echo done")
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("done"))
        XCTAssertGreaterThan(result.stderr.utf8.count, 65536)
    }

    func testFinalLineBeforeExitIsNeverLost() async throws {
        // Regression for the FILEPATH race: output written immediately before
        // exit (with no trailing newline) must reach both the collected data
        // and the line callback.
        let lock = NSLock()
        var lines: [String] = []
        let result = try await runProcess(
            shell("printf 'FILEPATH:/tmp/video.mp4'"),
            onStdoutLine: { line in lock.lock(); lines.append(line); lock.unlock() }
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines, ["FILEPATH:/tmp/video.mp4"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "FILEPATH:/tmp/video.mp4")
    }

    func testNonexistentExecutableThrows() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/binary")
        do {
            _ = try await runProcess(process)
            XCTFail("Expected runProcess to throw")
        } catch {
            // expected
        }
    }

    func testRegistryTerminateAllKillsRunningProcess() async throws {
        let process = shell("sleep 30")
        async let pending = runProcess(process)
        // Give the process a moment to start, then simulate app quit.
        try await Task.sleep(nanoseconds: 300_000_000)
        ProcessRegistry.shared.terminateAll()
        let result = try await pending
        XCTAssertNotEqual(result.status, 0, "terminated process should not report success")
    }

    func testProcessUnregisteredAfterCompletion() async throws {
        _ = try await runProcess(shell("true"))
        // terminateAll on an empty registry must be a no-op and not crash.
        ProcessRegistry.shared.terminateAll()
    }
}
