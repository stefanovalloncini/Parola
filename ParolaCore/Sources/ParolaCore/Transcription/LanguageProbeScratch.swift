import Foundation
import os

/// The short files a language probe listens to, one per window, cut under a deadline and deleted after.
enum LanguageProbeScratch {
    typealias Extract = @Sendable (_ source: URL, _ directory: URL) -> [URL]

    private enum Phase { case extracting, finished, abandoned }

    static func withScratch<Value>(
        from source: URL,
        deadline: Duration? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        extract: @escaping Extract = { source, directory in
            (try? ProbeAudioExtractor.extractWindows(from: source, into: directory)) ?? []
        },
        _ body: ([URL]) async throws -> Value
    ) async throws -> Value? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-language-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let phase = OSAllocatedUnfairLock(initialState: Phase.extracting)
        let read = await BoundedFileRead.run(deadline: deadline ?? FileReadDeadline.forReading(source), clock: clock) {
            let windows = extract(source, scratch)
            // A read that resumes after the deadline writes the scratch after the defer above has run.
            let abandoned = phase.withLock { phase -> Bool in
                if phase == .abandoned { return true }
                phase = .finished
                return false
            }
            if abandoned { try? FileManager.default.removeItem(at: scratch) }
            return windows
        }
        guard case .done(let windows) = read else {
            phase.withLock { $0 = .abandoned }
            throw ParolaError.fileReadTimedOut(name: source.lastPathComponent)
        }
        guard !windows.isEmpty else { return nil }
        return try await body(windows)
    }
}
