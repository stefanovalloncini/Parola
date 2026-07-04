import Foundation

public struct WordTimingSeed: Sendable {
    public var word: String
    public var start: Double
    public var end: Double
    public var probability: Double
    public var speaker: String?

    public init(
        word: String,
        start: Double,
        end: Double,
        probability: Double = 1.0,
        speaker: String? = nil
    ) {
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
        self.speaker = speaker
    }
}

public struct TranscriptSegmentSeed: Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var words: [WordTimingSeed]?

    public init(
        start: Double,
        end: Double,
        text: String,
        speaker: String? = nil,
        words: [WordTimingSeed]? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}

public struct MockTranscriberFailure: Sendable {
    public enum Code: String, Sendable {
        case transcriptionFailed
        case modelChecksumMismatch
        case unsupportedForEngine
        case engineNotRegistered
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    func asError() -> Error {
        switch code {
        case .transcriptionFailed:
            return ParolaError.transcriptionFailed(message)
        case .modelChecksumMismatch:
            return ParolaError.modelChecksumMismatch(file: message, expected: "", got: "")
        case .unsupportedForEngine:
            return ParolaError.unsupportedForEngine(message)
        case .engineNotRegistered:
            return ParolaError.engineNotRegistered(message)
        }
    }
}

public struct MockTranscriberResponse: Sendable {
    public var segments: [TranscriptSegmentSeed]
    public var partials: [String]
    public var progressSeconds: [Double]
    public var downloadFractions: [Double]
    public var language: String
    public var durationSeconds: Double
    public var modelName: String
    public var delayMs: Int
    public var failure: MockTranscriberFailure?

    public init(
        segments: [TranscriptSegmentSeed] = [],
        partials: [String] = [],
        progressSeconds: [Double] = [],
        downloadFractions: [Double] = [],
        language: String = "en",
        durationSeconds: Double = 0,
        modelName: String = "mock",
        delayMs: Int = 0,
        failure: MockTranscriberFailure? = nil
    ) {
        self.segments = segments
        self.partials = partials
        self.progressSeconds = progressSeconds
        self.downloadFractions = downloadFractions
        self.language = language
        self.durationSeconds = durationSeconds
        self.modelName = modelName
        self.delayMs = delayMs
        self.failure = failure
    }

    func materialise(sourceURL: URL?) -> Transcript {
        let realSegments = segments.enumerated().map { index, seed -> TranscriptSegment in
            let segmentID = index
            let words = seed.words?.enumerated().map { wordIndex, wordSeed in
                WordTiming(
                    id: "\(segmentID)-\(wordIndex)",
                    word: wordSeed.word,
                    start: wordSeed.start,
                    end: wordSeed.end,
                    probability: wordSeed.probability,
                    speaker: wordSeed.speaker
                )
            }
            return TranscriptSegment(
                id: segmentID,
                start: seed.start,
                end: seed.end,
                text: seed.text,
                speaker: seed.speaker,
                words: words
            )
        }
        return Transcript(
            segments: realSegments,
            language: language,
            modelName: modelName,
            sourceURL: sourceURL,
            durationSeconds: durationSeconds
        )
    }
}

public actor MockTranscriber: Transcriber {
    public static var engineID: EngineID { EngineID("mock") }
    public static var capabilities: EngineCapabilities {
        EngineCapabilities(
            supportedLanguages: .all,
            supportsTranslate: true,
            supportsInitialPrompt: true,
            supportsWordTimestamps: true,
            supportsDiarization: false
        )
    }

    private let response: MockTranscriberResponse
    private let sleeper: @Sendable (Int) async throws -> Void
    private var loadedModel: String?

    public init<C: Clock>(response: MockTranscriberResponse, clock: C) where C.Duration == Duration {
        self.response = response
        self.sleeper = { ms in
            try await Task.sleep(for: .milliseconds(ms), clock: clock)
        }
    }

    public func load(model: String) async throws {
        loadedModel = model
    }

    public func unload() async {
        loadedModel = nil
    }

    public func loadedModelName() async -> String? {
        loadedModel
    }

    public func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
        try await transcribe(url: url, options: options, partialHandler: nil, progressHandler: nil)
    }

    public func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?
    ) async throws -> Transcript {
        try await transcribe(url: url, options: options, partialHandler: partialHandler, progressHandler: nil)
    }

    public func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        if let failure = response.failure {
            if response.delayMs > 0 {
                try? await sleeper(response.delayMs)
            }
            throw failure.asError()
        }

        let stepCount = max(response.partials.count, response.progressSeconds.count)
        let perStepMs = stepCount > 0 ? max(0, response.delayMs / stepCount) : response.delayMs

        for step in 0..<stepCount {
            try Task.checkCancellation()
            if step < response.partials.count {
                partialHandler?(response.partials[step])
            }
            if step < response.progressSeconds.count {
                progressHandler?(response.progressSeconds[step])
            }
            if perStepMs > 0 {
                try? await sleeper(perStepMs)
            }
        }

        if stepCount == 0 && response.delayMs > 0 {
            try? await sleeper(response.delayMs)
        }

        try Task.checkCancellation()
        return response.materialise(sourceURL: url)
    }
}

extension MockTranscriber {
    public static func make(response: MockTranscriberResponse, clock: any Clock<Duration>) -> MockTranscriber {
        func bind<C: Clock>(_ clock: C) -> MockTranscriber where C.Duration == Duration {
            MockTranscriber(response: response, clock: clock)
        }
        return bind(clock)
    }
}
