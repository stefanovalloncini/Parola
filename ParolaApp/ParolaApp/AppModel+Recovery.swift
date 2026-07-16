import Foundation
import ParolaCore

/// What was in flight when Parola last quit: the source of a file transcription, or the
/// confirmed segments of a streaming recording, checkpointed every ~30s.
struct RecoveryCheckpoint: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fileTranscription
        case recording
    }

    var kind: Kind
    var startedAt: Date
    var modelName: String
    var sourceURL: URL?
    var language: String?
    var segments: [TranscriptSegment]

    init(
        kind: Kind,
        startedAt: Date,
        modelName: String,
        sourceURL: URL? = nil,
        language: String? = nil,
        segments: [TranscriptSegment] = []
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.language = language
        self.segments = segments
    }
}

extension AppModel {

    var recoveryFileURL: URL {
        library.libraryURL.appendingPathComponent("recovery.json")
    }

    @discardableResult
    func beginFileTranscribeRecovery(sourceURL: URL) -> Int {
        recoveryGeneration += 1
        activeRecoveryGeneration = recoveryGeneration
        recordingRecoveryStartedAt = nil
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .fileTranscription,
            startedAt: Date(),
            modelName: selectedModel,
            sourceURL: sourceURL
        ))
        return recoveryGeneration
    }

    @discardableResult
    func beginRecordingRecovery() -> Int {
        recoveryGeneration += 1
        activeRecoveryGeneration = recoveryGeneration
        recordingRecoveryStartedAt = Date()
        return recoveryGeneration
    }

    func writeRecordingCheckpoint() {
        guard activeRecoveryGeneration != nil, let startedAt = recordingRecoveryStartedAt else { return }
        guard !liveSegments.isEmpty else { return }
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .recording,
            startedAt: startedAt,
            modelName: selectedModel,
            language: selectedLanguage,
            segments: liveSegments
        ))
    }

    /// Generation-guarded delete so a superseded task's exit can't remove its successor's file.
    func endRecovery(_ generation: Int) {
        guard generation == activeRecoveryGeneration else { return }
        endActiveRecovery()
    }

    func endActiveRecovery() {
        guard activeRecoveryGeneration != nil else { return }
        activeRecoveryGeneration = nil
        recordingRecoveryStartedAt = nil
        try? FileManager.default.removeItem(at: recoveryFileURL)
    }

    private func writeRecoveryFile(_ checkpoint: RecoveryCheckpoint) {
        let url = recoveryFileURL
        let generation = activeRecoveryGeneration
        pendingRecoveryWrite = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(checkpoint) else { return }
            await MainActor.run { [weak self] in
                // Re-check after the encode: the recording may have ended meanwhile, and a late
                // write would resurrect a stale recovery prompt on the next launch.
                guard let self, self.activeRecoveryGeneration == generation else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Recording watch

    func startRecordingWatch(checkpoints: Bool) {
        recordingWatchTask?.cancel()
        let clock = clock
        recordingWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), clock: clock)
                if Task.isCancelled { return }
                guard let self else { return }
                self.checkRecordingDiskSpace()
                if checkpoints { self.writeRecordingCheckpoint() }
            }
        }
    }

    func stopRecordingWatch() {
        recordingWatchTask?.cancel()
        recordingWatchTask = nil
        if recordingDiskSpaceLow { recordingDiskSpaceLow = false }
    }

    // MARK: - Launch offer

    func loadPendingRecovery() {
        guard let data = try? Data(contentsOf: recoveryFileURL) else { return }
        guard let checkpoint = try? JSONDecoder().decode(RecoveryCheckpoint.self, from: data),
              Self.isRestorable(checkpoint) else {
            try? FileManager.default.removeItem(at: recoveryFileURL)
            return
        }
        pendingRecovery = checkpoint
    }

    private nonisolated static func isRestorable(_ checkpoint: RecoveryCheckpoint) -> Bool {
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        case .recording:
            return !checkpoint.segments.isEmpty
        }
    }

    func acceptPendingRecovery() {
        guard let checkpoint = pendingRecovery else { return }
        pendingRecovery = nil
        try? FileManager.default.removeItem(at: recoveryFileURL)
        switch checkpoint.kind {
        case .fileTranscription:
            if let url = checkpoint.sourceURL, FileManager.default.fileExists(atPath: url.path) {
                transcribe(fileURL: url)
            }
        case .recording:
            restoreRecoveredRecording(checkpoint)
        }
    }

    func declinePendingRecovery() {
        guard pendingRecovery != nil else { return }
        pendingRecovery = nil
        try? FileManager.default.removeItem(at: recoveryFileURL)
    }

    private func restoreRecoveredRecording(_ checkpoint: RecoveryCheckpoint) {
        let restored = Transcript(
            segments: checkpoint.segments,
            language: checkpoint.language ?? "en",
            modelName: checkpoint.modelName,
            durationSeconds: checkpoint.segments.last?.end
        )
        clearDerivedArtifacts()
        selectedEntryID = nil
        sourceFileURL = nil
        pendingMediaDuration = nil
        tearDownPlayer()
        transcript = restored
        phase = .ready
        route = .transcript
        persistToLibrary(restored, audioSource: nil, title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt))
    }

    nonisolated static func recoveredRecordingTitle(startedAt: Date) -> String {
        "Recording \(startedAt.formatted(date: .abbreviated, time: .shortened)) (recovered)"
    }
}
