import Foundation
import Testing
@testable import ParolaCore

@Suite("Log message")
struct LogMessageTests {
    @Test("a bare literal becomes one literal segment")
    func literalOnly() {
        let message: LogMessage = "transcribe failed"
        #expect(message.segments == [.literal("transcribe failed")])
        #expect(message.template == "transcribe failed")
        #expect(message.rendered == "transcribe failed")
    }

    @Test("interpolated LogSafe values are captured separately from literals")
    func separatesLiteralsFromValues() {
        let message: LogMessage = "model \(ModelToken("whisper-large-v3")) failed after \(61) s"
        #expect(message.template == "model %@ failed after %@ s")
        #expect(message.rendered == "model whisper-large-v3 failed after 61 s")
        #expect(message.segments == [
            .literal("model "),
            .value("whisper-large-v3"),
            .literal(" failed after "),
            .value("61"),
            .literal(" s"),
        ])
    }

    @Test("a literal containing a percent placeholder does not corrupt the template")
    func literalPercentIsNotAPlaceholder() {
        let message: LogMessage = "progress 50%@ done \(7)"
        #expect(message.rendered == "progress 50%@ done 7")
    }

    @Test("an absent optional renders as nil rather than dropping the field")
    func optionalRendersNil() {
        let missing: ModelToken? = nil
        let message: LogMessage = "model \(missing)"
        #expect(message.rendered == "model nil")
    }

    @Test("engine ids and features are loggable")
    func launchConformances() {
        #expect(EngineID.whisperKit.logToken == "whisperkit")
        #expect(ParolaFeature.dictation.logToken == "dictation")
    }
}
