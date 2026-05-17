import Foundation
import ParolaCore

actor MicDictationRecorder: DictationRecorder {
    private var source: MicAudioSource?
    private let session = TranscriptionSession()
    private let model: String?
    private let language: String?
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var forwardingTask: Task<Void, Never>?

    init(model: String?, language: String?) {
        self.model = model
        self.language = language
    }

    func start() async throws {
        guard source == nil else { return }
        let mic = MicAudioSource()
        try await mic.start()
        source = mic
        forwardingTask?.cancel()
        let stream = await mic.levels()
        forwardingTask = Task { [weak self] in
            for await level in stream {
                await self?.broadcast(level)
            }
        }
    }

    func stopAndTranscribe() async throws -> String {
        guard let source else { return "" }
        self.source = nil
        forwardingTask?.cancel()
        forwardingTask = nil
        broadcast(0)
        let url = try await source.prepare()
        let options = TranscriptionOptions(
            model: model,
            language: language,
            task: .transcribe
        )
        let transcript = try await session.transcribe(source: FileAudioSource(url: url), options: options)
        return transcript.text
    }

    func levels() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            levelContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeLevelContinuation(id) }
            }
        }
    }

    private func removeLevelContinuation(_ id: UUID) {
        levelContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ level: Float) {
        for continuation in levelContinuations.values {
            continuation.yield(level)
        }
    }
}
