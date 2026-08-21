import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("parola_transcribe arguments")
struct TranscribeRequestTests {

    // MARK: - Schema

    @Test("the transcribe schema advertises translate and initial_prompt")
    func schemaCarriesTheNewArguments() throws {
        let props = try transcribeProperties()

        let translate = try #require(props["translate"] as? [String: Any])
        #expect(translate["type"] as? String == "boolean")
        #expect(translate["default"] as? Bool == false)

        let prompt = try #require(props["initial_prompt"] as? [String: Any])
        #expect(prompt["type"] as? String == "string")
        #expect((prompt["description"] as? String)?.contains("224") == true)
    }

    @Test("the format enum matches the formats the tool can render")
    func schemaFormatEnumMatchesRenderer() throws {
        let format = try #require(try transcribeProperties()["format"] as? [String: Any])
        #expect(format["enum"] as? [String] == TranscribeFormat.allCases.map(\.rawValue))
    }

    // MARK: - Parsing

    @Test("translate and initial_prompt reach the transcription options")
    func translateAndPromptMapIntoOptions() throws {
        let request = try TranscribeRequest(args: [
            "path": "/tmp/talk.wav",
            "translate": true,
            "initial_prompt": "Parola, WhisperKit, Stefano",
            "format": "SRT",
        ])
        #expect(request.options.task == .translate)
        #expect(request.options.initialPrompt == "Parola, WhisperKit, Stefano")
        #expect(request.format == .srt)
        #expect(request.sourceURL.path == "/tmp/talk.wav")
    }

    @Test("the defaults transcribe verbatim")
    func defaultsLeaveEverythingOff() throws {
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav"])
        #expect(request.options.task == .transcribe)
        #expect(request.options.initialPrompt == nil)
        #expect(request.format == .txt)
    }

    @Test("a blank initial_prompt is dropped instead of biasing the decoder with nothing")
    func blankPromptIsDropped() throws {
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav", "initial_prompt": "   "])
        #expect(request.options.initialPrompt == nil)
    }

    @Test("a missing path is refused by name")
    func missingPathRefused() {
        #expect(throws: MCPToolError.self) { try TranscribeRequest(args: [:]) }
    }

    @Test("an unknown format is refused and lists the ones that work")
    func unknownFormatRefused() throws {
        let error = try #require(throws: MCPToolError.self) {
            try TranscribeRequest(args: ["path": "/tmp/talk.wav", "format": "docx"])
        }
        #expect(error.message.contains("docx"))
        #expect(error.message.contains("srt"))
    }

    // MARK: - Helpers

    private func transcribeProperties() throws -> [String: Any] {
        let data = try JSONEncoder().encode(EngineTool.transcribe.mcpTool)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try #require(parsed["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["path"])
        return try #require(schema["properties"] as? [String: Any])
    }
}
