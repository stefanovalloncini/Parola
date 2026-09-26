import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript chat condensed context")
struct TranscriptChatCondensedTests {
    private func seededTranscript() -> Transcript {
        var segments: [TranscriptSegment] = []
        for i in 0..<30 {
            segments.append(TranscriptSegment(
                id: i,
                start: Double(i) * 10,
                end: Double(i) * 10 + 9,
                text: String(repeating: "blah ", count: 40)
            ))
        }
        segments.append(TranscriptSegment(
            id: 30, start: 300, end: 309,
            text: "The Berlin office revenue grew twelve percent."
        ))
        segments.append(TranscriptSegment(
            id: 31, start: 600, end: 609,
            text: "We cooked a pasta carbonara recipe after the meeting."
        ))
        return Transcript(segments: segments.sorted { $0.start < $1.start }, language: "en", modelName: "tiny")
    }

    @Test("small transcripts stay on the full-transcript instructions")
    func underBudgetKeepsFullInstructions() {
        let small = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello")],
            language: "en",
            modelName: "tiny"
        )
        #expect(!TranscriptChat.usesCondensedContext(for: small, budgetTokens: TranscriptChat.defaultBudgetTokens))
        #expect(TranscriptChat.usesCondensedContext(for: seededTranscript(), budgetTokens: 400))
    }

    @Test("the size check reads the lines' lengths and decides as the built instructions did")
    func sizeCheckMatchesTheBuiltInstructions() {
        let texts = ["Hello", "  padded  ", "", "   ", "caffè perché", "👍🏽 emoji", "line\nbreak", String(repeating: "word ", count: 60)]
        let speakers: [String?] = [nil, "Ada", "  ", " Bo ", nil, "Ada", "", nil]
        for count in [1, 7, 40, 90, 400] {
            let segments = (0..<count).map { index in
                TranscriptSegment(
                    id: index,
                    start: Double(index) * 97.5,
                    end: Double(index) * 97.5 + 5,
                    text: texts[index % texts.count],
                    speaker: speakers[index % speakers.count]
                )
            }
            let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")
            let built = TranscriptChat.systemInstructions(for: transcript)
            #expect(
                TranscriptPromptContext.timestampedLinesUTF8Count(for: transcript)
                    == TranscriptPromptContext.timestampedLines(for: transcript).utf8.count
            )
            for budget in [1, 400, TranscriptChat.defaultBudgetTokens, 20_000, TokenBudget.estimateTokens(built)] {
                #expect(
                    TranscriptChat.usesCondensedContext(for: transcript, budgetTokens: budget)
                        == (TokenBudget.estimateTokens(built) > budget),
                    "\(count) segments, budget \(budget)"
                )
            }
        }
    }

    @Test("condensed instructions carry the digest and the question's segments")
    func condensedContainsDigestAndRelevantExcerpts() {
        let digest = Summary(
            text: "A quarterly review meeting.",
            chapters: [Chapter(title: "Revenue", start: 300)]
        )
        let out = TranscriptChat.condensedInstructions(
            for: seededTranscript(),
            question: "What happened to BERLIN revenue?",
            digest: digest,
            budgetTokens: 600
        )
        #expect(out.contains("A quarterly review meeting."))
        #expect(out.contains("05:00  Revenue"))
        #expect(out.contains("05:00  The Berlin office revenue grew twelve percent."))
        #expect(!out.contains("blah"))
        #expect(!out.contains("carbonara"))
    }

    @Test("relevant segments rank by case-folded keyword overlap and keep transcript order")
    func relevanceScoring() {
        let picked = TranscriptChat.relevantSegments(
            in: seededTranscript(),
            question: "What happened to BERLIN revenue?",
            maxTokens: 200
        )
        #expect(picked.map(\.id) == [30])

        let pasta = TranscriptChat.relevantSegments(
            in: seededTranscript(),
            question: "Tell me that pasta carbonara recipe",
            maxTokens: 200
        )
        #expect(pasta.first?.id == 31)
    }

    @Test("no keyword overlap yields no excerpts")
    func noOverlapNoExcerpts() {
        let picked = TranscriptChat.relevantSegments(
            in: seededTranscript(),
            question: "quantum entanglement",
            maxTokens: 200
        )
        #expect(picked.isEmpty)
    }

    @Test("over budget the chat model rebuilds instructions per question and caches the digest")
    func perTurnInstructions() async throws {
        let transcript = seededTranscript()
        let recorder = InstructionsRecorder()
        let inner = MockLanguageModel(scriptedResponses: ["twelve percent", "carbonara"])
        let digest = Summary(text: "Quarterly digest.", chapters: [])
        let model = CondensedChatModel(
            transcript: transcript,
            budgetTokens: 600,
            makeDigest: {
                await recorder.bumpDigest()
                return digest
            },
            makeModel: { instructions in
                await recorder.record(instructions)
                return inner
            }
        )

        let first = try await model.respond(history: [ChatTurn(role: .user, text: "What happened to Berlin revenue?")])
        #expect(first == "twelve percent")
        let second = try await model.respond(history: [
            ChatTurn(role: .user, text: "What happened to Berlin revenue?"),
            ChatTurn(role: .assistant, text: "twelve percent"),
            ChatTurn(role: .user, text: "Give me that pasta carbonara recipe"),
        ])
        #expect(second == "carbonara")

        let instructions = await recorder.instructions
        try #require(instructions.count == 2)
        #expect(instructions[0].contains("Quarterly digest."))
        #expect(instructions[0].contains("The Berlin office revenue grew twelve percent."))
        #expect(!instructions[0].contains("carbonara"))
        #expect(instructions[1].contains("Quarterly digest."))
        #expect(instructions[1].contains("pasta carbonara"))
        #expect(await recorder.digestBuilds == 1)
    }

    @Test("streaming through the condensed model reaches the inner model")
    func condensedStream() async throws {
        let inner = MockLanguageModel(scriptedResponses: ["ok"])
        let model = CondensedChatModel(
            transcript: seededTranscript(),
            budgetTokens: 600,
            makeDigest: { Summary(text: "Digest.", chapters: []) },
            makeModel: { _ in inner }
        )
        var collected = ""
        for try await chunk in model.stream(history: [ChatTurn(role: .user, text: "Berlin revenue?")]) {
            collected += chunk
        }
        #expect(collected == "ok")
    }
}

private actor InstructionsRecorder {
    private(set) var instructions: [String] = []
    private(set) var digestBuilds = 0

    func record(_ s: String) { instructions.append(s) }
    func bumpDigest() { digestBuilds += 1 }
}
