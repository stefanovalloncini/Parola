import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Incoming URL handling")
@MainActor
struct URLHandlingTests {
    private func makeModel() throws -> (AppModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-url-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let model = AppModel(libraryURL: tmp, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        return (model, tmp)
    }

    private var sampleAudioURL: URL {
        Bundle(for: BundleAnchor.self).url(forResource: "sample", withExtension: "wav")!
    }

    @Test("a .parola URL is adopted into the library")
    func adoptParola() async throws {
        let (model, _) = try makeModel()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-\(UUID().uuidString).parola", isDirectory: true)
        try ParolaDocument.write(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "x")],
                language: "en",
                modelName: "tiny"
            ),
            audioURL: sampleAudioURL,
            to: scratch
        )

        await model.handleIncoming(url: scratch)

        let entries = await model.library.list()
        #expect(entries.count == 1)
    }
}

private final class BundleAnchor {}
