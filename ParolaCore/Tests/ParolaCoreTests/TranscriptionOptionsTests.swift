import Foundation
import Testing
@testable import ParolaCore

@Suite("TranscriptionOptions")
struct TranscriptionOptionsTests {
    @Test("diarize forces wordTimestamps on even when passed false")
    func diarizeForcesWordTimestamps() {
        let options = TranscriptionOptions(wordTimestamps: false, diarize: true)
        #expect(options.diarize)
        #expect(options.wordTimestamps)
    }

    @Test("wordTimestamps stays on without diarize")
    func wordTimestampsWithoutDiarize() {
        let options = TranscriptionOptions(wordTimestamps: true, diarize: false)
        #expect(options.wordTimestamps)
        #expect(options.diarize == false)
    }

    @Test("both flags off leave wordTimestamps off")
    func bothOff() {
        let options = TranscriptionOptions(wordTimestamps: false, diarize: false)
        #expect(options.wordTimestamps == false)
        #expect(options.diarize == false)
    }

    @Test("both flags on stay on")
    func bothOn() {
        let options = TranscriptionOptions(wordTimestamps: true, diarize: true)
        #expect(options.wordTimestamps)
        #expect(options.diarize)
    }

    @Test("designated init keeps the other defaults")
    func initDefaults() {
        let options = TranscriptionOptions()
        #expect(options.model == nil)
        #expect(options.language == nil)
        #expect(options.task == .transcribe)
        #expect(options.wordTimestamps == false)
        #expect(options.verbose == false)
        #expect(options.initialPrompt == nil)
        #expect(options.diarize == false)
        #expect(options.expectedSpeakers == nil)
        #expect(options.chunkingStrategy == nil)
        #expect(options.computeUnits == nil)
    }

    @Test("default static value matches a fresh init")
    func staticDefault() {
        let fallback = TranscriptionOptions.default
        #expect(fallback.task == .transcribe)
        #expect(fallback.wordTimestamps == false)
        #expect(fallback.diarize == false)
        #expect(fallback.model == nil)
        #expect(fallback.language == nil)
    }

    @Test("explicit fields survive the init")
    func explicitFields() {
        let options = TranscriptionOptions(
            model: "openai_whisper-tiny",
            language: "it",
            task: .translate,
            verbose: true,
            initialPrompt: "Parola",
            expectedSpeakers: 2
        )
        #expect(options.model == "openai_whisper-tiny")
        #expect(options.language == "it")
        #expect(options.task == .translate)
        #expect(options.verbose)
        #expect(options.initialPrompt == "Parola")
        #expect(options.expectedSpeakers == 2)
    }

    @Test("TranscriptionTask exposes both cases")
    func taskCases() {
        #expect(TranscriptionTask.allCases == [.transcribe, .translate])
        #expect(TranscriptionTask(rawValue: "transcribe") == .transcribe)
        #expect(TranscriptionTask(rawValue: "translate") == .translate)
    }
}
