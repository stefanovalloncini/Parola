import Foundation

/// The short file a language probe listens to, cut from the loudest stretches of the source. The
/// cut runs off the caller's executor and on a deadline: the extractor seeks across the whole
/// source, and a read that parks there would park the engine with it.
enum LanguageProbeScratch {
    /// Hands `body` the scratch file and deletes it afterwards; nil when the source has nothing
    /// worth probing.
    static func withScratch<Value>(
        from source: URL,
        deadline: Duration? = nil,
        _ body: (URL) async throws -> Value
    ) async throws -> Value? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-language-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let read = await BoundedFileRead.run(deadline: deadline ?? FileReadDeadline.forReading(source)) {
            let windows = try? ProbeAudioExtractor.extract(from: source, to: scratch)
            return windows?.isEmpty == false
        }
        guard case .done(let extracted) = read else {
            throw ParolaError.fileReadTimedOut(name: source.lastPathComponent)
        }
        guard extracted else { return nil }
        return try await body(scratch)
    }
}
