import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum TranscriptChatProvider: Sendable, Hashable {
    case onDevice
    case cloud(CloudLLMProviderID)
}

public enum TranscriptChat {
    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = []
    ) throws -> TranscriptChatSession {
        let model = try makeOnDeviceModel(instructions: systemInstructions(for: transcript))
        return TranscriptChatSession(transcript: transcript, history: history, model: model)
    }

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        provider: TranscriptChatProvider,
        keyStore: APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared
    ) async throws -> TranscriptChatSession {
        let instructions = systemInstructions(for: transcript)
        let model: any LanguageModel
        switch provider {
        case .onDevice:
            model = try makeOnDeviceModel(instructions: instructions)
        case .cloud(let id):
            model = try await LanguageModelFactory.makeBYOKCloud(
                provider: id,
                instructions: instructions,
                keyStore: keyStore,
                managed: managed
            )
        }
        return TranscriptChatSession(transcript: transcript, history: history, model: model)
    }

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        model: any LanguageModel
    ) -> TranscriptChatSession {
        TranscriptChatSession(transcript: transcript, history: history, model: model)
    }

    static func systemInstructions(for transcript: Transcript) -> String {
        var out = """
        You answer questions about a transcript. Be concise — one or two sentences unless the user asks for more. When you reference a moment from the audio, include its timestamp in MM:SS or HH:MM:SS form.

        Transcript follows. Each line is prefixed with its timestamp.


        """
        for segment in transcript.segments {
            let ts = Timecode.format(segment.start)
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(ts)  \(body)\n"
        }
        return out
    }

    private static func makeOnDeviceModel(instructions: String) throws -> any LanguageModel {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return FoundationLanguageModel(instructions: instructions)
            case .unavailable(let reason):
                throw TranscriptChatSession.FailureReason.notAvailable("On-device language model is not available (\(reason)).")
            @unknown default:
                throw TranscriptChatSession.FailureReason.notAvailable("On-device language model availability is unknown.")
            }
        }
        #endif
        throw TranscriptChatSession.FailureReason.notAvailable("Foundation Models requires macOS 26 / iOS 26 or newer.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct FoundationLanguageModel: LanguageModel {
    private let instructions: String

    public init(instructions: String) {
        self.instructions = instructions
    }

    public func respond(history: [ChatTurn]) async throws -> String {
        let (session, prompt) = try makeSession(history: history)
        let r = try await session.respond(to: prompt)
        return r.content
    }

    public func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (session, prompt) = try makeSession(history: history)
                    let response = session.streamResponse(to: prompt)
                    var lastEmitted = ""
                    for try await snapshot in response {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        guard current.count >= lastEmitted.count else { continue }
                        let delta = String(current.dropFirst(lastEmitted.count))
                        if !delta.isEmpty {
                            continuation.yield(delta)
                            lastEmitted = current
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession(history: [ChatTurn]) throws -> (LanguageModelSession, String) {
        guard let last = history.last, last.role == .user else {
            throw TranscriptChatSession.FailureReason.modelError("History must end with a user turn.")
        }
        var entries: [FoundationModels.Transcript.Entry] = []
        entries.append(.instructions(
            FoundationModels.Transcript.Instructions(
                segments: [.text(.init(content: instructions))],
                toolDefinitions: []
            )
        ))
        for turn in history.dropLast() {
            switch turn.role {
            case .user:
                entries.append(.prompt(
                    FoundationModels.Transcript.Prompt(segments: [.text(.init(content: turn.text))])
                ))
            case .assistant:
                entries.append(.response(
                    FoundationModels.Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.text))])
                ))
            }
        }
        let session = LanguageModelSession(transcript: FoundationModels.Transcript(entries: entries))
        return (session, last.text)
    }
}
#endif
