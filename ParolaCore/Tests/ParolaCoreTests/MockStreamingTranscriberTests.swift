import Foundation
import Testing
@testable import ParolaCore

@Suite("Mock streaming transcriber")
struct MockStreamingTranscriberTests {
    @Test("emits partials, then confirmed segments, then finished")
    func emitsScriptedEvents() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello world")],
            partials: ["hel", "hello", "hello world"],
            language: "en",
            durationSeconds: 1,
            modelName: "mock",
            delayMs: 0
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"),
                                          speakerLabeler: nil, downloadProgress: nil)
        let collector = Task { () -> ([String], [String], Transcript?) in
            var p: [String] = []; var c: [String] = []; var f: Transcript?
            for await event in stream {
                switch event {
                case .partial(let t): p.append(t)
                case .confirmed(let s): c.append(s.text)
                case .finished(let t): f = t
                default: break
                }
            }
            return (p, c, f)
        }
        await mock.stop()
        let (partials, confirmed, finished) = await collector.value
        #expect(partials == ["hel", "hello", "hello world"])
        #expect(confirmed == ["hello world"])
        #expect(finished?.segments.first?.text == "hello world")
    }
}
