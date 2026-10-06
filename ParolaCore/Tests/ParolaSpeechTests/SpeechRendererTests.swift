import Foundation
import Testing
import ParolaCore
import ParolaSpeech

@Suite("SpeechRenderer")
struct SpeechRendererTests {
    @MainActor
    private final class MainActorRenderer: SpeechRenderer {
        nonisolated let engine = SpeechEngineKind.apple
        nonisolated let capabilities = SpeechRendererCapabilities(
            languages: ["en"], expandsNumbers: true, usesNeuralEngine: false, nominalRTF: 0.02, maxUnitChars: 400
        )
        private(set) var cancelled = false

        func render(
            text: String,
            unitID: Int,
            voice: VoiceID,
            language: String
        ) async throws -> AsyncThrowingStream<PCMChunk, any Error> {
            MainActor.assertIsolated()
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self, throwing: (any Error).self)
            continuation.yield(PCMChunk(unitID: unitID, samples: [0.25, -0.25], sampleRate: 22_050))
            continuation.finish()
            return stream
        }

        func cancel() async {
            cancelled = true
        }

        func prewarm(voice: VoiceID, language: String) async throws {}
    }

    private actor Caller {
        func read(with renderer: any SpeechRenderer) async throws -> [PCMChunk] {
            var chunks: [PCMChunk] = []
            let stream = try await renderer.render(text: "Hi", unitID: 7, voice: .appleAutomatic, language: "en")
            for try await chunk in stream { chunks.append(chunk) }
            await renderer.cancel()
            return chunks
        }
    }

    @Test("main-actor and actor renderers both serve a caller on another actor")
    func isolationShapes() async throws {
        let mainActorRenderer = MainActorRenderer()
        let renderers: [any SpeechRenderer] = [mainActorRenderer, MockSpeechRenderer(secondsPerCharacter: 0.01)]
        let caller = Caller()
        for renderer in renderers {
            let chunks = try await caller.read(with: renderer)
            let units = Set(chunks.map(\.unitID))
            #expect(units == [7])
        }
        let cancelled = await mainActorRenderer.cancelled
        #expect(cancelled)
    }

    @Test("a chunk's duration is its sample count over its rate")
    func chunkDuration() {
        #expect(PCMChunk(unitID: 0, samples: Array(repeating: 0, count: 11_025), sampleRate: 22_050).duration == 0.5)
        #expect(PCMChunk(unitID: 0, samples: [0, 0], sampleRate: 0).duration == 0)
    }
}
