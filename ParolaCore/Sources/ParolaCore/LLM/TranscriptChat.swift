import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum TranscriptChat {
    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = []
    ) throws -> TranscriptChatSession {
        let model = try makeModel(transcript: transcript)
        return TranscriptChatSession(transcript: transcript, history: history, model: model)
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

    private static func makeModel(transcript: Transcript) throws -> any LanguageModel {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                let session = LanguageModelSession(instructions: systemInstructions(for: transcript))
                return FoundationLanguageModel(session: session)
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
public actor FoundationLanguageModel: LanguageModel {
    private let session: LanguageModelSession

    public init(session: LanguageModelSession) {
        self.session = session
    }

    public func respond(to prompt: String) async throws -> String {
        let r = try await session.respond(to: prompt)
        return r.content
    }
}
#endif
