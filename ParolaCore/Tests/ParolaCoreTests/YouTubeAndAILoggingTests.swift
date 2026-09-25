import Foundation
import Testing
@testable import ParolaCore

private struct ThrowingLanguageModel: LanguageModel {
    struct Failure: Error {}

    func respond(history: [ChatTurn]) async throws -> String {
        throw Failure()
    }
}

@Suite("YouTube and AI logging", .serialized)
struct YouTubeAndAILoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func records(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == category && $0.message.rendered == message }
    }

    private func coreSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "Tests/ParolaCoreTests/YouTubeAndAILoggingTests.swift",
            with: "Sources/ParolaCore/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("a provider outside the known set never reaches a log")
    func providerAllowlist() {
        #expect(CloudLLMProviderID.openAI.logToken == "openai")
        #expect(CloudLLMProviderID.anthropic.logToken == "anthropic")
        #expect(CloudLLMProviderID("acme-internal").logToken == "unrecognized")
        #expect(CloudLLMProviderID("../../etc/passwd").logToken == "unrecognized")
    }

    @Test("an unsupported host is logged without the URL")
    func unsupportedURL() async throws {
        try await withSink { sink in
            let url = URL(string: "https://videos.example.com/watch?v=secret")!
            #expect(throws: ParolaError.self) {
                _ = try YouTubeAudioSource(url: url, features: .all)
            }

            let record = try #require(
                records(sink, .youtube, message: "URL is not on a host yt-dlp can fetch from").first
            )
            #expect(record.level == .notice)
            #expect(record.formattedLine.contains("example.com") == false)
            #expect(record.formattedLine.contains("secret") == false)
        }
    }

    @Test("a yt-dlp run that overruns its timeout is logged with the timeout, not the URL")
    func timeoutLogged() async throws {
        try await withSink { sink in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["5"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()

            // A zero timeout fires at once, so the blocking wait behind it never holds a
            // cooperative thread long enough to slow the suites running beside this one.
            await #expect(throws: ParolaError.self) {
                try await YouTubeProcess.waitWithTimeout(process, seconds: 0)
            }

            let record = try #require(
                records(sink, .youtube, message: "yt-dlp timed out after 0s").first
            )
            #expect(record.level == .error)
            #expect(process.isRunning == false)
        }
    }

    @Test("a cloud request that fails logs the provider and the status, never the body")
    func cloudRequestFailure() async throws {
        try await withSink { sink in
            let handler = MockTransport.Handler { _ in
                .status(503, body: "upstream said: the transcript of the meeting")
            }
            let model = CloudLanguageModel(
                provider: .openAI, apiKey: "sk-test", session: MockTransport.makeSession(handler: handler)
            )

            await #expect(throws: (any Error).self) {
                _ = try await model.respond(history: [ChatTurn(role: .user, text: "hi")])
            }

            let record = try #require(
                records(sink, .ai, message: "openai request failed with HTTP 503").first
            )
            #expect(record.level == .error)
            #expect(record.formattedLine.contains("transcript of the meeting") == false)
        }
    }

    @Test("a failing stream logs the provider and the error kind")
    func cloudStreamFailure() async throws {
        try await withSink { sink in
            let handler = MockTransport.Handler { _ in .status(500, body: "boom") }
            let model = CloudLanguageModel(
                provider: .anthropic, apiKey: "sk-test", session: MockTransport.makeSession(handler: handler)
            )

            await #expect(throws: (any Error).self) {
                for try await _ in model.stream(history: [ChatTurn(role: .user, text: "hi")]) {}
            }

            let record = try #require(records(sink, .ai, message: "anthropic stream failed").first)
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("boom") == false)
        }
    }

    @Test("a summary model that throws is logged with its error kind, not its message")
    func summaryModelFailure() async throws {
        try await withSink { sink in
            let service = SummaryService(features: .all)
            let transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "quarterly numbers")],
                language: "en",
                modelName: "stub"
            )

            await #expect(throws: SummaryService.FailureReason.self) {
                _ = try await service.summarise(transcript, model: ThrowingLanguageModel())
            }

            let record = try #require(records(sink, .ai, message: "summary model failed").first)
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("quarterly") == false)
        }
    }

    /// The remaining sites need `yt-dlp`, an unreachable Apple Intelligence state, or a refusing keychain — pinned in source.
    @Test("the sites that cannot be driven here are still present and still safe")
    func pinnedSites() throws {
        for name in ["Audio/YouTubeAudioSource", "Audio/YouTubeSubsFetcher"] {
            let youtube = try coreSource(name)
            #expect(youtube.contains(
                #"ParolaLog.error(.youtube, "yt-dlp could not be launched", [.error: .error(error)])"#
            ))
            #expect(youtube.contains(
                #"ParolaLog.error(.youtube, "yt-dlp exited with status \(Int(process.terminationStatus))", [.error: .error(error)])"#
            ))
        }

        let factory = try coreSource("LLM/LanguageModelFactory")
        #expect(factory.contains(
            #"ParolaLog.notice(.ai, "on-device model unavailable: \(Self.unavailability())")"#
        ))

        let summary = try coreSource("LLM/SummaryService")
        #expect(summary.contains(
            #"ParolaLog.error(.ai, "on-device summary model failed", [.error: .error(error)])"#
        ))

        let keychain = try coreSource("LLM/Cloud/APIKeyStore")
        for operation in ["read", "update", "add", "delete"] {
            #expect(keychain.contains(#"ParolaLog.error(.ai, "keychain \#(operation) failed with OSStatus"#))
        }

        for name in [
            "Audio/YouTubeAudioSource", "Audio/YouTubeSubsFetcher", "Audio/YouTubeProcess", "LLM/LanguageModelFactory",
            "LLM/Cloud/CloudLanguageModel", "LLM/SummaryService", "LLM/Cloud/APIKeyStore",
        ] {
            for chunk in try coreSource(name).components(separatedBy: "ParolaLog.").dropFirst() {
                #expect(chunk.hasPrefix("error") || chunk.hasPrefix("notice"), "\(name) logs at an odd level")
                var depth = 0
                var call = ""
                for character in chunk {
                    call.append(character)
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                #expect(call.contains("localizedDescription") == false, "\(name) logs a localized description")
            }
        }
    }
}
