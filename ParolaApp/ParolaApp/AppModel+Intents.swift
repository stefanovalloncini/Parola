import Foundation
import ParolaCore

enum IntentActionError: LocalizedError, Equatable {
    case recordingInProgress
    case batchInProgress
    case transcriptionInProgress
    case exportInProgress
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
        case .exportInProgress:
            return "Parola is exporting a video right now. Wait for it to finish."
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

/// A finished file run's hand-off to the library: the text it produced and the save still copying its media.
struct FileRunLanding {
    let runToken: Int
    let text: String
    let entry: Task<LibraryEntry, any Error>
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

    /// Shortcuts can't answer the duplicate sheet, and the file's scope ends on return, so this waits for the media copy.
    func transcribeFileFromIntent(_ url: URL) async throws -> String {
        try ensureIntentCanStartFileRun()
        guard url.isFileURL, url.pathExtension.lowercased() != "parola", !Self.isSubtitleImport(url) else {
            throw IntentActionError.notMedia
        }
        introduction.defer()
        let digest = await SourceDigest.digest(of: url, deadline: fileReadDeadline)
        if let digest, duplicateImportPolicy != .transcribeAgain,
           let existing = await library.findEntry(digest: digest) {
            try ensureIntentCanStartFileRun()
            do {
                return try await openEntry(existing.id).text
            } catch is CancellationError {
                throw IntentActionError.cancelled
            } catch {
                throw IntentActionError.failed(error.localizedDescription)
            }
        }
        try ensureIntentCanStartFileRun()
        beginFileTranscription(fileURL: url, translateOverride: nil, sourceDigest: digest)
        guard let run = fileTranscribeTask else {
            throw IntentActionError.failed("Parola couldn't start transcribing \(url.lastPathComponent).")
        }
        let runToken = fileRunGeneration
        await run.value
        guard let landing = fileRunLanding, landing.runToken == runToken else {
            if case .failed(let message) = phase { throw IntentActionError.failed(message) }
            throw IntentActionError.cancelled
        }
        do {
            _ = try await landing.entry.value
        } catch {
            throw IntentActionError.failed(error.localizedDescription)
        }
        return landing.text
    }

    /// Checked again after every await: a drop or a recording can start while the file hashes.
    private func ensureIntentCanStartFileRun() throws {
        switch phase {
        case .recording: throw IntentActionError.recordingInProgress
        case .exporting: throw IntentActionError.exportInProgress
        default: break
        }
        if batchIsRunning { throw IntentActionError.batchInProgress }
        if transcribeTaskRunning { throw IntentActionError.transcriptionInProgress }
    }

    func stopRecordingFromIntent() async throws -> String {
        guard case .recording = phase else { throw IntentActionError.notRecording }
        stopRecordingAndTranscribe()
        guard streamingConsumer != nil || fileTranscribeTask != nil || stopHeldForStartup else {
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
