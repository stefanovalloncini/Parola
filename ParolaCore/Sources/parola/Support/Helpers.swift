import Foundation
import os
import ParolaCore

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Runs `body` with the process's stdout (fd 1) pointed at stderr, then restores it. FluidAudio's
/// Parakeet models make the CoreML runtime print `E5RT …` shape-inference chatter straight to fd 1
/// on the first inference; without this the noise lands in the transcript we print to stdout and
/// breaks machine-readable output (`parola transcribe -f json | jq` chokes on the leading text).
func withStdoutRedirectedToStderr<T>(_ body: () async throws -> T) async rethrows -> T {
    fflush(stdout)
    let savedStdout = dup(STDOUT_FILENO)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    defer {
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
    }
    return try await body()
}

/// The notice for a run about to proceed as English on an English-only model instead of silently
/// probing a language it can't act on. nil for a multilingual model. The CLI refuses an explicit
/// `-l` on the wrong language elsewhere; this only covers the auto-language case.
func englishOnlyAutoNoticeText(model: String) -> String? {
    guard let variant = ModelCatalog.variant(id: model),
          ModelCatalog.staticCapabilities(for: variant)?.supportedLanguages.isEnglishOnly == true
    else { return nil }
    return "\(variant.displayName) only transcribes English; transcribing as English. Pass -l to pick a multilingual model."
}

func printEnglishOnlyAutoNotice(model: String) {
    if let text = englishOnlyAutoNoticeText(model: model) {
        stderr(text)
    }
}

/// The library a command reads: the `--library` folder when one is given, the app's otherwise.
func libraryStore(at path: String?) -> LibraryStore {
    if let path { LibraryStore.sharedLibraryOverride = URL(fileURLWithPath: path, isDirectory: true) }
    return .shared
}

func humanBytes(_ bytes: Int) -> String {
    Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
        .formatted(.byteCount(style: .file))
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// A download bar on stderr, drawn once per whole percent and written under a lock, so the closing newline lands last.
final class ProgressReporter: Sendable {
    private struct State {
        var percent = -1
        var finished = false
    }

    private let label: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(label: String) { self.label = label }

    func update(_ fraction: Double) {
        state.withLock { state in
            let pct = max(0, min(100, Int(fraction * 100)))
            guard !state.finished, pct != state.percent else { return }
            state.percent = pct
            let bars = pct / 5
            let bar = String(repeating: "█", count: bars) + String(repeating: "·", count: 20 - bars)
            FileHandle.standardError.write(Data("\r\(label) [\(bar)] \(pct)%".utf8))
        }
    }

    func finish() {
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            if state.percent >= 0 { FileHandle.standardError.write(Data("\n".utf8)) }
        }
    }
}

func awaitStop(seconds: Double?) async {
    let stop = AsyncSignalStream(signal: SIGINT)
    let timer: Task<Void, Never>? = seconds.map { secs in
        Task {
            try? await Task.sleep(for: .seconds(secs), clock: ContinuousClock())
            stop.fire()
        }
    }
    await stop.wait()
    timer?.cancel()
}

struct Interrupted: Error {}

/// Runs `body` until SIGINT/SIGTERM, which cancels it and waits for it to unwind before throwing `Interrupted`.
/// A value `body` still finishes with after the signal goes to `abandon`, so whatever it holds can be cleaned up.
func untilInterrupted<T: Sendable>(
    abandoning abandon: @escaping @Sendable (T) -> Void = { _ in },
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let signals = [AsyncSignalStream(signal: SIGINT), AsyncSignalStream(signal: SIGTERM)]
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        for stream in signals {
            group.addTask {
                await stream.wait()
                return nil
            }
        }
        // Wakes whichever waiter is still parked, or the group would wait on it forever.
        defer { for stream in signals { stream.fire() } }
        let first = try await group.next() ?? nil
        group.cancelAll()
        guard let first else {
            for stream in signals { stream.fire() }
            while let late = await group.nextResult() {
                if case .success(let value?) = late { abandon(value) }
            }
            throw Interrupted()
        }
        return first
    }
}

/// While alive, SIGINT or SIGTERM runs `cleanup` and ends the process with 130, the status a shell gives an interrupted command.
final class InterruptCleanup: Sendable {
    private let streams: [AsyncSignalStream]
    private let watchers: [Task<Void, Never>]

    /// `_exit`, not `exit`: the engines still run on other threads, and `exit` would tear down statics they use.
    init(_ cleanup: @escaping @Sendable () -> Void, ending: @escaping @Sendable (Int32) -> Void = { _exit($0) }) {
        let streams = [AsyncSignalStream(signal: SIGINT), AsyncSignalStream(signal: SIGTERM)]
        self.streams = streams
        watchers = streams.map { stream in
            Task.detached {
                await stream.wait()
                guard !Task.isCancelled else { return }
                cleanup()
                ending(130)
            }
        }
    }

    func stop() {
        for watcher in watchers { watcher.cancel() }
        for stream in streams { stream.fire() }
    }
}

/// Unchecked Sendable: `semaphore` is its own synchronization; `source` is `let` and `DispatchSourceSignal` is thread-safe.
final class AsyncSignalStream: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let source: DispatchSourceSignal
    private let sig: Int32

    init(signal sig: Int32) {
        self.sig = sig
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        self.source = source
        source.setEventHandler { [semaphore] in semaphore.signal() }
        source.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.semaphore.wait()
                cont.resume()
            }
        }
    }

    func fire() {
        semaphore.signal()
    }

    deinit {
        source.cancel()
        // Restore default handling: leaving SIG_IGN would make the process ignore
        // Ctrl-C for the whole transcription that follows the recording.
        signal(sig, SIG_DFL)
    }
}
