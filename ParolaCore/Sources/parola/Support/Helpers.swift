import Foundation

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func humanBytes(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024, idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    return String(format: "%.1f %@", value, units[idx])
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// Renders a simple progress bar to stderr. Safe to call from any thread.
final class ProgressReporter: @unchecked Sendable {
    private let label: String
    private let queue = DispatchQueue(label: "com.parola.progress")
    private var lastPercent: Int = -1
    private var finished = false

    init(label: String) { self.label = label }

    func update(_ fraction: Double) {
        queue.async {
            guard !self.finished else { return }
            let pct = max(0, min(100, Int(fraction * 100)))
            guard pct != self.lastPercent else { return }
            self.lastPercent = pct
            let bars = pct / 5
            let bar = String(repeating: "█", count: bars) + String(repeating: "·", count: 20 - bars)
            FileHandle.standardError.write(Data("\r\(self.label) [\(bar)] \(pct)%".utf8))
        }
    }

    func finish() {
        queue.sync {
            guard !self.finished else { return }
            self.finished = true
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}

/// Awaits a single delivery of a Unix signal (e.g. SIGINT) using async/await.
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
