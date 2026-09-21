import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct CardMetadata: Sendable, Equatable {
    public var title: String
    public var summary: String

    public init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }

    public static func sanitizedTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = title.firstIndex(of: "\n") { title = String(title[..<newline]) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.,;: "))
        return String(title.prefix(80))
    }

    public static func sanitizedSummary(_ raw: String) -> String {
        var summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = summary.firstIndex(of: "\n") { summary = String(summary[..<newline]) }
        summary = summary.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“” "))
        return String(summary.prefix(160))
    }
}

public struct CardMetadataPrompts: Sendable, Equatable {
    public var title: String?
    public var summary: String?

    public init(title: String? = nil, summary: String? = nil) {
        self.title = title
        self.summary = summary
    }
}

public enum CardMetadataService {
    public enum Failure: Error, Equatable {
        case tooShort
        case featureDisabled
    }

    public static let minimumCharacters = 40
    static let excerptCharacters = 3000

    public static func generate(
        for transcript: Transcript,
        prompts: CardMetadataPrompts = .init(),
        features: FeatureSet = .resolve()
    ) async throws -> CardMetadata {
        guard features.isEnabled(.ai) else { throw Failure.featureDisabled }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumCharacters else { throw Failure.tooShort }
        let excerpt = String(text.prefix(excerptCharacters))
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *),
           await MockLanguageModelStore.shared.resolve(for: .foundation) == nil {
            return try await generateStructured(excerpt: excerpt, prompts: prompts)
        }
        #endif
        let model = try await LanguageModelFactory.makeOnDevice(instructions: textInstructions(prompts))
        return parse(try await model.respond(to: excerpt))
    }

    static func parse(_ reply: String) -> CardMetadata {
        let lines = reply.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = CardMetadata.sanitizedTitle(lines.first ?? "")
        let summary = CardMetadata.sanitizedSummary(lines.dropFirst().first ?? "")
        return CardMetadata(title: title, summary: summary)
    }

    static func textInstructions(_ prompts: CardMetadataPrompts) -> String {
        let title = prompts.title ?? "a title of 3 to 6 words"
        let summary = prompts.summary ?? "one sentence of at most 140 characters saying what the recording is about"
        return "Reply with exactly two lines in the language of the transcript. Line 1: \(title). Line 2: \(summary). No quotes, no labels, no preamble."
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private static func generateStructured(excerpt: String, prompts: CardMetadataPrompts) async throws -> CardMetadata {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw LanguageModelFactory.Failure.notAvailable(LanguageModelFactory.unavailableMessage(for: reason))
        @unknown default:
            throw LanguageModelFactory.Failure.notAvailable("Apple Intelligence isn't available right now.")
        }

        let session = LanguageModelSession(instructions: textInstructions(prompts))
        let response = try await session.respond(to: excerpt, generating: GenerableCardMetadata.self)
        return CardMetadata(
            title: CardMetadata.sanitizedTitle(response.content.title),
            summary: CardMetadata.sanitizedSummary(response.content.summary)
        )
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable
struct GenerableCardMetadata: Sendable {
    @Guide(description: "Three to six words, in the language of the transcript, no quotes.")
    var title: String

    @Guide(description: "One sentence of at most 140 characters saying what the recording is about, in the language of the transcript.")
    var summary: String
}
#endif
