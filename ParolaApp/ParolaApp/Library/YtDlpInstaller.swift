import Foundation
import os
import ParolaCore

/// Drives `brew install` and `brew upgrade`, off the AppModel.
enum YtDlpInstaller {
    enum Outcome: Equatable, Sendable {
        case success
        case failure(String)
        case timedOut
        case cancelled
    }

    static let upgradeDeadline: Duration = .seconds(600)

    enum BrewCommand: String, LogSafe {
        case install
        case upgrade

        var logToken: String { rawValue }
    }

    enum BrewFailureKind: String, LogSafe {
        case download
        case locked
        case notInstalled
        case permission
        case other

        var logToken: String { rawValue }
    }

    static func install(formula: String, brewPath: String) async -> Outcome {
        await runBrew(.install, formula: formula, brewPath: brewPath, autoUpdate: false, deadline: nil)
    }

    static func upgrade(formula: String, brewPath: String, deadline: Duration = upgradeDeadline) async -> Outcome {
        await runBrew(.upgrade, formula: formula, brewPath: brewPath, autoUpdate: true, deadline: deadline)
    }

    /// brew's own `Error:` lines, at most the last two; auto-update reports and hints never reach the UI.
    static func errorSummary(of output: String) -> String? {
        let errors = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Error:") }
            .map { $0.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return errors.isEmpty ? nil : errors.suffix(2).joined(separator: "\n")
    }

    static func launchFailureMessage(_ detail: String, bundle: Bundle = .main) -> String {
        String(localized: "Could not launch brew: \(detail)", bundle: bundle)
    }

    static func exitStatusMessage(_ status: Int, bundle: Bundle = .main) -> String {
        String(localized: "brew exited with status \(status).", bundle: bundle)
    }

    static func failureKind(of summary: String?) -> BrewFailureKind {
        let text = summary?.lowercased() ?? ""
        func mentions(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        if mentions(["failed to download", "download failed", "curl:", "could not resolve", "timed out"]) { return .download }
        if mentions(["already in progress", "is locked", "another active homebrew"]) { return .locked }
        if mentions(["not installed", "no such keg", "no available formula"]) { return .notInstalled }
        if mentions(["permission denied", "not writable", "operation not permitted"]) { return .permission }
        return .other
    }

    static func brewEnvironment(autoUpdate: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // An upgrade needs brew's auto-update: without it brew only knows the versions it fetched last time.
        env["HOMEBREW_NO_AUTO_UPDATE"] = autoUpdate ? nil : "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_UPDATE_REPORT_NEW"] = "1"
        return env
    }

    private static func runBrew(
        _ command: BrewCommand, formula: String, brewPath: String, autoUpdate: Bool, deadline: Duration?
    ) async -> Outcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = [command.rawValue, formula]
        proc.environment = brewEnvironment(autoUpdate: autoUpdate)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: Data.self)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(chunk)
            }
        }

        let exitSignal = ExitSignal()
        proc.terminationHandler = { _ in exitSignal.fire() }

        let bufferTask = Task<String, Never> {
            var data = Data()
            for await chunk in chunkStream {
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            chunkContinuation.finish()
            return .failure(launchFailureMessage(error.localizedDescription))
        }
        let started = ContinuousClock.now
        let ending = await waitForExit(proc, exited: exitSignal, deadline: deadline)
        // brew's Error line is usually its last, so wait for the pipe's end; a child still holding it gets two seconds.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await bufferTask.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            if await group.next() != true {
                pipe.fileHandleForReading.readabilityHandler = nil
                chunkContinuation.finish()
            }
            group.cancelAll()
        }
        let output = await bufferTask.value
        let elapsed = LogValue.duration(started.duration(to: .now))
        switch ending {
        case .timedOut:
            ParolaLog.error(.youtube, "brew \(command) hit its deadline", [.elapsed: elapsed])
            return .timedOut
        case .cancelled:
            ParolaLog.notice(.youtube, "brew \(command) cancelled", [.elapsed: elapsed])
            return .cancelled
        case .exited:
            let status = Int(proc.terminationStatus)
            if status == 0 {
                ParolaLog.info(.youtube, "brew \(command) finished", [.elapsed: elapsed])
                return .success
            }
            let summary = errorSummary(of: output)
            let lines = output.split(whereSeparator: \.isNewline).count
            ParolaLog.error(
                .youtube, "brew \(command) exited with status \(status)",
                [.error: .safe(failureKind(of: summary)), .count: .int(lines), .elapsed: elapsed]
            )
            return .failure(summary ?? exitStatusMessage(status))
        }
    }

    private enum Ending: Sendable {
        case exited
        case timedOut
        case cancelled
    }

    private static func waitForExit(_ proc: Process, exited: ExitSignal, deadline: Duration?) async -> Ending {
        await withTaskGroup(of: Ending.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await exited.wait()
                } onCancel: {
                    stop(proc)
                }
                return Task.isCancelled ? .cancelled : .exited
            }
            if let deadline {
                group.addTask {
                    guard (try? await Task.sleep(for: deadline)) != nil else { return .cancelled }
                    stop(proc)
                    return .timedOut
                }
            }
            let first = await group.next() ?? .exited
            group.cancelAll()
            return first
        }
    }

    /// SIGTERM lets brew release its lock; SIGKILL follows if it's still running after the grace period.
    private static func stop(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10)) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Fired by a termination handler set before `run()`, so brew's exit is never missed and no thread blocks waiting for it.
private final class ExitSignal: Sendable {
    private struct State {
        var exited = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire() {
        let waiters = state.withLock { state in
            state.exited = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state in
                if !state.exited { state.waiters.append(continuation) }
                return state.exited
            }
            if exited { continuation.resume() }
        }
    }
}
