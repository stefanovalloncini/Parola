import Foundation

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
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
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
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

    init(signal sig: Int32) {
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
    }
}
