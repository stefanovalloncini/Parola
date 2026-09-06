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
        let message: LogMessage = "model \(ModelToken("openai_whisper-large-v3")) failed after \(61) s"
        #expect(message.template == "model %@ failed after %@ s")
        #expect(message.rendered == "model openai_whisper-large-v3 failed after 61 s")
        #expect(message.segments == [
            .literal("model "),
            .value("openai_whisper-large-v3"),
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

    @Test("String and URL must never conform to LogSafe")
    func stringIsNotLogSafe() {
        #expect(("x" as Any) as? any LogSafe == nil)
        #expect((URL(fileURLWithPath: "/x") as Any) as? any LogSafe == nil)
    }

    /// A public memberwise init would let a caller rebuild a record from strings — what the StaticString pin prevents.
    @Test("LogRecord's memberwise init stays internal")
    func recordInitIsNotPublic() throws {
        let source = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ParolaCore/Diagnostics/LogRecord.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "public struct LogRecord"))
        let body = text[start.lowerBound...]
        let end = try #require(body.range(of: "\n}\n"))
        let declaration = body[..<end.upperBound]
        #expect(declaration.contains("\n    init(\n"))
        #expect(!declaration.contains("public init"))
    }
}
