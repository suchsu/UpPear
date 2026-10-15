import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let error: String
}

public enum CommandRunner {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 120,
                           allowBrewAutoUpdate: Bool = false,
                           environmentOverrides: [String: String] = [:]) async throws -> CommandResult {
        let task = ProcessTask()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try task.execute(executable: executable, arguments: arguments, timeout: timeout,
                                 allowBrewAutoUpdate: allowBrewAutoUpdate, environmentOverrides: environmentOverrides)
            }.value
        } onCancel: { task.cancel() }
    }
}

/// Process is confined to one worker. Only cancellation and the timeout access
/// its lifecycle concurrently, under the lock. Output goes to temporary files
/// so a full stderr/stdout pipe cannot deadlock a long Homebrew command.
private final class ProcessTask: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func execute(executable: URL, arguments: [String], timeout: TimeInterval,
                 allowBrewAutoUpdate: Bool, environmentOverrides: [String: String]) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpPear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if !allowBrewAutoUpdate { environment["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Overrides apply to this child only, never global/user settings.
        environment.merge(environmentOverrides) { _, supplied in supplied }
        child.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            self.cancel()
        }
        timer.resume()
        child.waitUntilExit()
        timer.cancel()
        lock.lock()
        process = nil
        let wasTimedOut = timedOut
        let wasCancelled = cancelled
        lock.unlock()
        if wasTimedOut { throw CheckError.timedOut }
        if wasCancelled { throw CancellationError() }
        try stdout.synchronize()
        try stderr.synchronize()
        return CommandResult(exitCode: child.terminationStatus,
            output: try Self.readBounded(stdoutURL), error: try Self.readBounded(stderrURL))
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let child = process, child.isRunning {
            let pid = child.processIdentifier
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let active = self.process, active.processIdentifier == pid, active.isRunning { kill(pid, SIGKILL) }
                self.lock.unlock()
            }
        }
        lock.unlock()
    }

    private static func readBounded(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit: UInt64 = 16 * 1024 * 1024
        try handle.seek(toOffset: size > limit ? size - limit : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}
