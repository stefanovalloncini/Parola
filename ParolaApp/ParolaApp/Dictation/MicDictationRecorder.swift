import Foundation
import ParolaCore

actor MicDictationRecorder: DictationRecorder {
    private var source: MicAudioSource?
    private let session = TranscriptionSession()
    private let model: String?
    private let language: String?

    init(model: String?, language: String?) {
        self.model = model
        self.language = language
    }

    func start() async throws {
        guard source == nil else { return }
        let mic = MicAudioSource()
        try await mic.start()
        source = mic
    }

    func stopAndTranscribe() async throws -> String {
        guard let source else { return "" }
        self.source = nil
        let url = try await source.prepare()
        let options = TranscriptionOptions(
            model: model,
            language: language,
            task: .transcribe
        )
        let transcript = try await session.transcribe(source: FileAudioSource(url: url), options: options)
        return transcript.text
    }
}
