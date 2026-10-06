import Foundation
import ParolaCore

/// A run of mono samples from one reading unit, at the rate the renderer produced them. The only audio
/// value that crosses isolation: an `AVAudioPCMBuffer` never leaves the code that made it.
public struct PCMChunk: Sendable, Equatable {
    public let unitID: Int
    public let samples: [Float]
    public let sampleRate: Double

    public init(unitID: Int, samples: [Float], sampleRate: Double) {
        self.unitID = unitID
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// What a renderer supports, fixed for its lifetime. `languages` holds base codes ("en", "it") and an
/// empty set means any language; `nominalRTF` is render time over audio time on a typical Mac.
public struct SpeechRendererCapabilities: Sendable, Hashable {
    public var languages: Set<String>
    public var expandsNumbers: Bool
    public var usesNeuralEngine: Bool
    public var nominalRTF: Double
    public var maxUnitChars: Int

    public init(
        languages: Set<String>,
        expandsNumbers: Bool,
        usesNeuralEngine: Bool,
        nominalRTF: Double,
        maxUnitChars: Int
    ) {
        self.languages = languages
        self.expandsNumbers = expandsNumbers
        self.usesNeuralEngine = usesNeuralEngine
        self.nominalRTF = nominalRTF
        self.maxUnitChars = maxUnitChars
    }
}

/// Turns text into audio for one voice. A render runs from the call until its stream finishes, throws or
/// is cancelled (dropping the stream cancels it), and `cancel()` returns once it has stopped; a prewarm
/// runs until it returns. Callers never pass empty or whitespace-only text and never start a render or a
/// prewarm while either runs. The requirements are async so actor and main-actor renderers conform alike.
public protocol SpeechRenderer: Sendable {
    var engine: SpeechEngineKind { get }
    var capabilities: SpeechRendererCapabilities { get }

    func render(
        text: String,
        unitID: Int,
        voice: VoiceID,
        language: String
    ) async throws -> AsyncThrowingStream<PCMChunk, any Error>

    func cancel() async

    func prewarm(voice: VoiceID, language: String) async throws
}
