#if os(macOS)
import Foundation
import os

/// One yt-dlp run, read line by line as it prints and ended by a watchdog rather than left to hang.
enum YtDlpRunner {
    enum Watch: Sendable {
        /// A fixed budget for the whole run: fine for runs that print nothing until they are done.
        case wallClock(seconds: Int)
        /// A download is ended only once it stops making progress.
        case progress(ProgressLimits)
    }

    struct ProgressLimits: Sendable {
        /// Extraction prints nothing under `--print`, so the stretch before the video's metadata gets its own allowance.
        var startup: Duration = .seconds(120)
        /// The longest a download may go without a progress line once the metadata is in.
        var quiet: Duration = .seconds(60)
        /// Ends a download that keeps making progress for longer than any video Parola should fetch.
        var ceiling: Duration = .seconds(4 * 3600)
        var processingFloor: Duration = .seconds(120)
        var processingPerMediaSecond = 0.25
        var processingUnknownLength: Duration = .seconds(600)

        /// ffmpeg prints nothing while it converts, so post-processing gets a budget that grows with the video.
        func processing(mediaSeconds: Double?) -> Duration {
            guard let mediaSeconds, mediaSeconds > 0 else { return processingUnknownLength }
            return max(processingFloor, .seconds(mediaSeconds * processingPerMediaSecond))
        }
    }

    struct Output: Sendable {
        var status: Int32
        /// Every stdout line that isn't one of Parola's markers.
        var stdout: [String]
        var stderr: String
        var lines: [YtDlpLine]

        var stdoutText: String { stdout.joined(separator: "\n") }

        var metadata: LinkMetadata? {
            lines.lazy.compactMap { if case .metadata(let metadata) = $0 { metadata } else { nil } }.last
        }

        var filePath: String? {
            lines.lazy.compactMap { if case .file(let path) = $0 { path } else { nil } }.last
        }
    }

    static func run(
        ytDlpPath: String,
        arguments: [String],
        run: YtDlpRun,
        watch: Watch,
        onLine: @escaping @Sendable (YtDlpLine) -> Void = { _ in }
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = arguments
        process.environment = YouTubeProcess.augmentedEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutLines = PipeLines(stdoutPipe)
        let stderrLines = PipeLines(stderrPipe)
        let watchdog = Watchdog(watch)

        let exit: ExitSignal
        do {
            exit = try YouTubeProcess.start(process)
        } catch {
            stdoutLines.stop()
            stderrLines.stop()
            ParolaLog.error(.youtube, "yt-dlp could not be launched", [.error: .error(error)])
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .toolFailedToStart))
        }

        let stdoutReader = Task<([String], [YtDlpLine]), Never> {
            var plain: [String] = []
            var parsed: [YtDlpLine] = []
            for await line in stdoutLines.stream {
                if let marked = YtDlpLine(line) {
                    watchdog.observe(marked)
                    parsed.append(marked)
                    onLine(marked)
                } else {
                    plain.append(line)
                }
            }
            return (plain, parsed)
        }
        let stderrReader = Task<String, Never> {
            var text: [String] = []
            for await line in stderrLines.stream {
                if let marked = YtDlpLine(line) {
                    watchdog.observe(marked)
                    onLine(marked)
                } else {
                    text.append(line)
                }
            }
            return text.joined(separator: "\n")
        }

        let ending = await withTaskGroup(of: Ending.self) { group in
            group.addTask {
                await exit.wait()
                return .exited
            }
            group.addTask { await watchdog.expiry() }
            let first = await group.next() ?? .exited
            if case .exited = first {} else { stop(process) }
            group.cancelAll()
            return first
        }
        // A grandchild that inherited a pipe would hold it open past the exit, so the readers get two seconds to finish.
        let drained = await AsyncTimeout.run(.seconds(2)) { () async -> Bool in
            _ = await stdoutReader.value
            _ = await stderrReader.value
            return true
        }
        if drained == nil {
            stdoutLines.stop()
            stderrLines.stop()
        }
        let (plain, parsed) = await stdoutReader.value
        let stderr = await stderrReader.value

        switch ending {
        case .exited:
            return Output(status: process.terminationStatus, stdout: plain, stderr: stderr, lines: parsed)
        case .cancelled:
            throw CancellationError()
        case .wallClock(let seconds):
            ParolaLog.error(.youtube, "yt-dlp \(run) timed out after \(seconds)s")
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .timedOut(seconds: seconds)))
        case .stalled(let seconds):
            ParolaLog.error(.youtube, "yt-dlp \(run) stalled for \(seconds)s")
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .stalled(seconds: seconds)))
        }
    }

    enum Ending: Sendable {
        case exited
        case cancelled
        case wallClock(seconds: Int)
        case stalled(seconds: Int)
    }

    /// SIGTERM reaches yt-dlp's whole process group, ffmpeg included; five seconds on, SIGKILL goes to the same group.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
            kill(-pid, SIGKILL)
        }
    }

    /// Keeps the run's deadline: fixed for a wall clock, pushed out by each metadata or progress line for a download.
    final class Watchdog: Sendable {
        private struct State {
            var deadline: ContinuousClock.Instant
            var expiry: Ending
            var mediaSeconds: Double?
        }

        private let watch: Watch
        private let ceiling: ContinuousClock.Instant
        private let state: OSAllocatedUnfairLock<State>

        init(_ watch: Watch, now: ContinuousClock.Instant = .now) {
            self.watch = watch
            switch watch {
            case .wallClock(let seconds):
                ceiling = now + .seconds(seconds)
                state = OSAllocatedUnfairLock(initialState: State(deadline: ceiling, expiry: .wallClock(seconds: seconds)))
            case .progress(let limits):
                ceiling = now + limits.ceiling
                state = OSAllocatedUnfairLock(initialState: State(
                    deadline: now + limits.startup, expiry: .stalled(seconds: Self.wholeSeconds(limits.startup))
                ))
            }
        }

        func observe(_ line: YtDlpLine) {
            guard case .progress(let limits) = watch else { return }
            let now = ContinuousClock.now
            state.withLock { state in
                switch line {
                case .metadata(let metadata):
                    state.mediaSeconds = metadata.duration
                    Self.pushQuietDeadline(&state, now: now, limits: limits)
                case .downloaded:
                    Self.pushQuietDeadline(&state, now: now, limits: limits)
                case .processing:
                    let budget = limits.processing(mediaSeconds: state.mediaSeconds)
                    state.deadline = now + budget
                    state.expiry = .wallClock(seconds: Self.wholeSeconds(budget))
                case .file:
                    break
                }
            }
        }

        /// Returns once the deadline passes with no line pushing it out, or `.cancelled` when the run is.
        func expiry() async -> Ending {
            while !Task.isCancelled {
                let (deadline, ending) = state.withLock { ($0.deadline, $0.expiry) }
                let now = ContinuousClock.now
                if now >= ceiling, case .progress(let limits) = watch {
                    return .wallClock(seconds: Self.wholeSeconds(limits.ceiling))
                }
                if now >= deadline { return ending }
                // A line can also bring the deadline closer, so no single sleep outlasts a second.
                try? await Task.sleep(until: min(deadline, ceiling, now + .seconds(1)), clock: .continuous)
            }
            return .cancelled
        }

        private static func pushQuietDeadline(_ state: inout State, now: ContinuousClock.Instant, limits: ProgressLimits) {
            guard case .stalled = state.expiry else { return }
            state.deadline = now + limits.quiet
            state.expiry = .stalled(seconds: wholeSeconds(limits.quiet))
        }

        private static func wholeSeconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds)
        }
    }
}

/// A pipe's output as lines, handed over as they arrive instead of once the process has exited.
final class PipeLines: Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let handle: FileHandle
    private let pending = OSAllocatedUnfairLock(initialState: Data())

    init(_ pipe: Pipe) {
        (stream, continuation) = AsyncStream.makeStream(of: String.self)
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [pending, continuation] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                let rest = pending.withLock { data in
                    defer { data = Data() }
                    return data
                }
                if !rest.isEmpty { continuation.yield(Self.line(rest)) }
                continuation.finish()
                return
            }
            let lines = pending.withLock { data in
                data.append(chunk)
                var lines: [String] = []
                while let newline = data.firstIndex(of: 0x0A) {
                    lines.append(Self.line(data[data.startIndex..<newline]))
                    data.removeSubrange(data.startIndex...newline)
                }
                return lines
            }
            for line in lines { continuation.yield(line) }
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        continuation.finish()
    }

    private static func line(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
#endif
