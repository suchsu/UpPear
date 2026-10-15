// Modified for UpPear on 2026-10-14 by WorkBuddy (接管续作).
// Covers CommandRunner success, non-zero exit, timeout and cancellation paths.
// Uses only system tools; does not touch Homebrew or user software.
import XCTest
@testable import UpPearCore

final class CommandRunnerTests: XCTestCase {

    private let echo = URL(fileURLWithPath: "/bin/echo")
    private let sleep = URL(fileURLWithPath: "/bin/sleep")
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testSuccessfulCommand() async throws {
        let result = try await CommandRunner.run(executable: echo, arguments: ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("hello"))
    }

    func testNonZeroExitCode() async throws {
        let result = try await CommandRunner.run(executable: sh, arguments: ["-c", "exit 3"])
        XCTAssertEqual(result.exitCode, 3)
    }

    func testEnvironmentOverrideIsConfinedToChild() async throws {
        let before = ProcessInfo.processInfo.environment["UPPEAR_TEST_ONLY"]
        let result = try await CommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["UPPEAR_TEST_ONLY"], environmentOverrides: ["UPPEAR_TEST_ONLY": "child-value"])
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "child-value")
        XCTAssertEqual(ProcessInfo.processInfo.environment["UPPEAR_TEST_ONLY"], before)
    }

    func testTimeoutThrows() async {
        do {
            _ = try await CommandRunner.run(executable: sleep, arguments: ["10"], timeout: 0.3)
            XCTFail("expected timeout")
        } catch let error as CheckError {
            guard case .timedOut = error else { return XCTFail("unexpected error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationThrows() async {
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        let task = Task {
            try await CommandRunner.run(executable: sleepURL, arguments: ["10"], timeout: 30)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
