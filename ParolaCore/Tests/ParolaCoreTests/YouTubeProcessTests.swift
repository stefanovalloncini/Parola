#if os(macOS)
import Foundation
import Testing
@testable import ParolaCore

@Suite("YouTubeProcess waiter")
struct YouTubeProcessTests {
    @Test("waitWithTimeout returns when the process exits naturally")
    func waitsForNaturalExit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        // A clock nobody advances can never reach the deadline, so returning at all proves the
        // process exited on its own.
        try await YouTubeProcess.waitWithTimeout(process, seconds: 5, clock: TestClock())
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test("waitWithTimeout throws and terminates when the process overruns")
    func timesOutOnSlowProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        await #expect(throws: ParolaError.self) {
            try await YouTubeProcess.waitWithTimeout(process, seconds: 1)
        }
        #expect(process.isRunning == false)
    }

    @Test("waitWithTimeout copes with a process that exits before the wait registers")
    func handlesAlreadyExitedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        // Give the process a moment to exit before we start waiting.
        try await Task.sleep(for: .milliseconds(150))
        try await YouTubeProcess.waitWithTimeout(process, seconds: 5, clock: TestClock())
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test("PipeDrain collects pipe output without blocking the producer")
    func pipeDrainCollectsLargeOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Roughly 200 KB of output, well above the typical 64 KB pipe buffer.
        process.arguments = ["-c", "yes hello | head -n 20000"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let drain = PipeDrain(pipe: stdout)
        try process.run()
        try await YouTubeProcess.waitWithTimeout(process, seconds: 10, clock: TestClock())
        let collected = drain.data()
        #expect(collected.count > 100_000)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }
}
#endif
