import Foundation
import Testing
@testable import ParolaCore

@Suite("Log allowlist enforcement at the LogSafe conformance level")
struct LogAllowlistTests {
    @Test("a known engine id survives through LogValue.safe")
    func knownEngineIDSurvives() {
        #expect(LogValue.safe(EngineID.whisperKit).text == "whisperkit")
    }

    @Test("an arbitrary engine id is redacted through LogValue.safe")
    func arbitraryEngineIDIsRedacted() {
        #expect(LogValue.safe(EngineID("/Users/realname/evil")).text == "unrecognized")
    }

    @Test("a catalog model id survives through ModelToken")
    func catalogModelIDSurvivesThroughModelToken() {
        #expect(LogValue.safe(ModelToken("openai_whisper-large-v3_turbo")).text
            == "openai_whisper-large-v3_turbo")
    }

    @Test("an arbitrary path is redacted through ModelToken")
    func arbitraryPathIsRedactedThroughModelToken() {
        #expect(LogValue.safe(ModelToken("/Users/realname/notes.txt")).text == "unrecognized")
    }

    @Test("an unsafe engine id interpolated into a LogMessage never carries a path")
    func logMessageInterpolationDropsPath() {
        let engine = EngineID("/Users/realname/evil")
        let message: LogMessage = "engine \(engine)"
        let text = message.rendered
        #expect(text.contains("/") == false)
        #expect(text.contains("Users") == false)
    }
}
