import Foundation
import ParolaCore

enum IntentActionError: LocalizedError, Equatable {
    case recordingInProgress
    case batchInProgress
    case transcriptionInProgress
    case notRecording
    case notMedia
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .recordingInProgress:
            return "Parola is recording right now. Stop the recording first."
        case .batchInProgress:
            return "Parola is running a batch right now. Wait for it to finish."
        case .transcriptionInProgress:
            return "Parola is already transcribing. Wait for it to finish."
        case .notRecording:
            return "No recording is running."
        case .notMedia:
            return "Pick an audio or video file."
        case .cancelled:
            return "The work was cancelled."
        case .failed(let message):
            return message
        }
    }
}

extension AppModel {

    func registerIntentPerformers() {
        IntentPerformers.transcribeFile = { [weak self] url in
            guard let self else { throw IntentActionError.cancelled }
            return try await self.transcribeFileFromIntent(url)
        }
        IntentPerformers.stopRecording = { [weak self] in
            guard let self else { throw IntentActionError.cancelled }
            return try await self.stopRecordingFromIntent()
        }
    }

    func transcribeFileFromIntent(_ url: URL) async throws -> String {
        if case .recording = phase { throw IntentActionError.recordingInProgress }
        if batchIsRunning { throw IntentActionError.batchInProgress }
        if transcribeTaskRunning { throw IntentActionError.transcriptionInProgress }
        guard url.pathExtension.lowercased() != "parola", !Self.isSubtitleImport(url) else {
            throw IntentActionError.notMedia
        }
        transcribe(fileURL: url)
        guard let task = fileTranscribeTask else {
            throw IntentActionError.failed("Parola couldn't start transcribing \(url.lastPathComponent).")
        }
        await task.value
        if case .failed(let message) = phase { throw IntentActionError.failed(message) }
        guard phase == .ready, let transcript else { throw IntentActionError.cancelled }
        return transcript.text
    }

    func stopRecordingFromIntent() async throws -> String {
        guard case .recording = phase else { throw IntentActionError.notRecording }
        stopRecordingAndTranscribe()
        guard streamingConsumer != nil || fileTranscribeTask != nil else {
            throw IntentActionError.notRecording
        }
        return try await awaitRecordingOutcome()
    }

    func awaitRecordingOutcome() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            recordingOutcomeWaiters.append(continuation)
        }
    }

    func resolveRecordingOutcome(_ result: Result<String, any Error>) {
        guard !recordingOutcomeWaiters.isEmpty else { return }
        let waiters = recordingOutcomeWaiters
        recordingOutcomeWaiters = []
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
