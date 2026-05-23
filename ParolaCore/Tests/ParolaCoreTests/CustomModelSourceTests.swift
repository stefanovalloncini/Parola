import Foundation
import Testing
@testable import ParolaCore

@Suite("Custom model source parser")
struct CustomModelSourceTests {
    struct ParseCase: Sendable {
        let name: String
        let input: String
        let expectedRepo: String
        let expectedRevision: String?
        let expectedDisplayName: String?

        init(
            _ name: String,
            input: String,
            repo: String,
            revision: String? = nil,
            displayName: String? = nil
        ) {
            self.name = name
            self.input = input
            self.expectedRepo = repo
            self.expectedRevision = revision
            self.expectedDisplayName = displayName
        }
    }

    @Test(
        "parses valid input",
        arguments: [
            ParseCase(
                "huggingface.co URL to owner/repo",
                input: "https://huggingface.co/openai/whisper-large-v3",
                repo: "openai/whisper-large-v3",
                revision: "main",
                displayName: "whisper-large-v3"
            ),
            ParseCase(
                "strips trailing slashes and whitespace",
                input: "  https://huggingface.co/openai/whisper-tiny/  ",
                repo: "openai/whisper-tiny"
            ),
            ParseCase(
                "extracts revision from /tree/<branch> URLs",
                input: "https://huggingface.co/openai/whisper-base/tree/v2",
                repo: "openai/whisper-base",
                revision: "v2"
            ),
            ParseCase(
                "accepts plain owner/repo input",
                input: "openai/whisper-small",
                repo: "openai/whisper-small"
            ),
        ]
    )
    func parses(_ testCase: ParseCase) throws {
        let source = try #require(CustomModelSource.parse(testCase.input))
        #expect(source.repo == testCase.expectedRepo)
        if let revision = testCase.expectedRevision {
            #expect(source.revision == revision)
        }
        if let displayName = testCase.expectedDisplayName {
            #expect(source.displayName == displayName)
        }
    }

    @Test(
        "rejects invalid input",
        arguments: [
            (name: "single-segment string", input: "whisper-small"),
            (name: "single-segment huggingface URL", input: "https://huggingface.co/openai"),
            (name: "github host", input: "https://github.com/openai/whisper"),
            (name: "example.com host", input: "http://example.com/repo"),
            (name: "empty string", input: ""),
            (name: "whitespace only", input: "   "),
        ]
    )
    func rejects(name: String, input: String) {
        #expect(CustomModelSource.parse(input) == nil)
    }
}
