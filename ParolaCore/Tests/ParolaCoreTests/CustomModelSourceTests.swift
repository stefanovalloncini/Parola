import Foundation
import Testing
@testable import ParolaCore

@Suite("Custom model source parser")
struct CustomModelSourceTests {
    @Test("parses a huggingface.co URL to owner/repo")
    func huggingFaceRoot() {
        let source = CustomModelSource.parse("https://huggingface.co/openai/whisper-large-v3")
        #expect(source?.repo == "openai/whisper-large-v3")
        #expect(source?.revision == "main")
    }

    @Test("strips trailing slashes and whitespace")
    func tolerantWhitespace() {
        let source = CustomModelSource.parse("  https://huggingface.co/openai/whisper-tiny/  ")
        #expect(source?.repo == "openai/whisper-tiny")
    }

    @Test("extracts revision from /tree/<branch> URLs")
    func treeBranch() {
        let source = CustomModelSource.parse("https://huggingface.co/openai/whisper-base/tree/v2")
        #expect(source?.repo == "openai/whisper-base")
        #expect(source?.revision == "v2")
    }

    @Test("accepts plain owner/repo input")
    func plainOwnerRepo() {
        let source = CustomModelSource.parse("openai/whisper-small")
        #expect(source?.repo == "openai/whisper-small")
    }

    @Test("rejects single-segment input")
    func rejectsSingleSegment() {
        #expect(CustomModelSource.parse("whisper-small") == nil)
        #expect(CustomModelSource.parse("https://huggingface.co/openai") == nil)
    }

    @Test("rejects unknown hosts")
    func rejectsForeignHost() {
        #expect(CustomModelSource.parse("https://github.com/openai/whisper") == nil)
        #expect(CustomModelSource.parse("http://example.com/repo") == nil)
    }

    @Test("display name is the last path segment")
    func displayName() {
        let source = CustomModelSource.parse("https://huggingface.co/openai/whisper-large-v3")
        #expect(source?.displayName == "whisper-large-v3")
    }

    @Test("rejects empty input")
    func rejectsEmpty() {
        #expect(CustomModelSource.parse("") == nil)
        #expect(CustomModelSource.parse("   ") == nil)
    }
}
