import Foundation
import os

/// The short file a language probe listens to, cut under a deadline and deleted once the probe is done.
enum LanguageProbeScratch {
    typealias Extract = @Sendable (_ source: URL, _ scratch: URL) -> Bool

    private enum Phase { case extracting, finished, abandoned }

    static func withScratch<Value>(
        from source: URL,
        deadline: Duration? = nil,
        extract: @escaping Extract = { source, scratch in
            (try? ProbeAudioExtractor.extract(from: source, to: scratch))?.isEmpty == false
        },
        _ body: (URL) async throws -> Value
    ) async throws -> Value? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-language-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let phase = OSAllocatedUnfairLock(initialState: Phase.extracting)
        let read = await BoundedFileRead.run(deadline: deadline ?? FileReadDeadline.forReading(source)) {
            let extracted = extract(source, scratch)
            // A read that resumes after the deadline writes the scratch after the defer above has run.
            let abandoned = phase.withLock { phase -> Bool in
                if phase == .abandoned { return true }
                phase = .finished
                return false
            }
            if abandoned { try? FileManager.default.removeItem(at: scratch) }
            return extracted
        }
        guard case .done(let extracted) = read else {
            phase.withLock { $0 = .abandoned }
            throw ParolaError.fileReadTimedOut(name: source.lastPathComponent)
        }
        guard extracted else { return nil }
        return try await body(scratch)
    }
}
