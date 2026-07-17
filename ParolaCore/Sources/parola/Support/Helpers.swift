import Foundation

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

actor ProgressReporter {
    private let label: String
    private var lastPercent: Int = -1
    private var finished = false

    init(label: String) { self.label = label }

    nonisolated func update(_ fraction: Double) {
        Task { await self.write(fraction) }
    }

    private func write(_ fraction: Double) {
        guard !finished else { return }
        let pct = max(0, min(100, Int(fraction * 100)))
        guard pct != lastPercent else { return }
        lastPercent = pct
        let bars = pct / 5
        let bar = String(repeating: "█", count: bars) + String(repeating: "·", count: 20 - bars)
        FileHandle.standardError.write(Data("\r\(label) [\(bar)] \(pct)%".utf8))
    }

    nonisolated func finish() {
        Task { await self.finalize() }
    }

    private func finalize() {
        guard !finished else { return }
        finished = true
        FileHandle.standardError.write(Data("\n".utf8))
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
