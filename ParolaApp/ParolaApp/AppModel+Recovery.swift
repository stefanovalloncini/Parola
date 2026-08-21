import AVFoundation
import Foundation
import ParolaCore

private let recoveryFileQueue = DispatchQueue(label: "app.parola.recovery-file")

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
    var audioURL: URL?
    var title: String?

    init(
        kind: Kind,
        startedAt: Date,
        modelName: String,
        sourceURL: URL? = nil,
        language: String? = nil,
        segments: [TranscriptSegment] = [],
        audioURL: URL? = nil,
        title: String? = nil
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.language = language
        self.segments = segments
        self.audioURL = audioURL
        self.title = title
    }
}

extension AppModel {

    var recoveryFileURL: URL {
        library.libraryURL.appendingPathComponent("recovery.json")
    }

    @discardableResult
    func beginFileTranscribeRecovery(sourceURL: URL, title: String? = nil) -> Int {
        recoveryGeneration += 1
        activeRecoveryGeneration = recoveryGeneration
        recordingRecoveryStartedAt = nil
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .fileTranscription,
            startedAt: Date(),
            modelName: selectedModel,
            sourceURL: sourceURL,
            title: title
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
        guard !liveSegments.isEmpty || liveRecordingAudioURL != nil else { return }
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .recording,
            startedAt: startedAt,
            modelName: selectedModel,
            language: selectedLanguage,
            segments: liveSegments,
            audioURL: liveRecordingAudioURL
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
        let url = recoveryFileURL
        // Synchronous on the same queue the writes use: a checkpoint already queued must land
        // before this delete, or it resurrects the prompt after the recording stopped.
        recoveryFileQueue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private func writeRecoveryFile(_ checkpoint: RecoveryCheckpoint) {
        let url = recoveryFileURL
        let generation = activeRecoveryGeneration
        pendingRecoveryWrite = Task { [weak self] in
            guard let data = try? await AppModel.offMainIO({ try JSONEncoder().encode(checkpoint) }) else { return }
            // Re-check after the encode: the recording may have ended meanwhile, and a late
            // write would resurrect a stale recovery prompt on the next launch.
            guard let self, self.activeRecoveryGeneration == generation else { return }
            // Queued in the same main-actor step as the check above, so an endActiveRecovery
            // that lands after it still drains this write before deleting the file.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recoveryFileQueue.async {
                    try? data.write(to: url, options: .atomic)
                    continuation.resume()
                }
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
            if !checkpoint.segments.isEmpty { return true }
            guard let audioURL = checkpoint.audioURL else { return false }
            return FileManager.default.fileExists(atPath: audioURL.path)
        }
    }

    func acceptPendingRecovery() {
        guard let checkpoint = pendingRecovery else { return }
        pendingRecovery = nil
        try? FileManager.default.removeItem(at: recoveryFileURL)
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL, FileManager.default.fileExists(atPath: url.path) else { return }
            if let title = checkpoint.title {
                // A recorded take mid-transcription when the app died: the take path keeps
                // its title and saves the audio if this run fails too.
                fileTranscribeTask?.cancel()
                fileTranscribeTask = Task { [weak self] in
                    guard let self else { return }
                    await transcribeRecordedTake(url: url, title: title)
                    if !Task.isCancelled {
                        self.fileTranscribeTask = nil
                        self.drainDeferredArrivals()
                    }
                }
            } else {
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
        guard let candidate = checkpoint.audioURL else {
            finishRecordingRestore(checkpoint, audioURL: nil)
            return
        }
        // A crash can leave the in-flight WAV with a stale header; attach it only
        // when it still opens, and probe off-main (AVAudioFile can block).
        Task { [weak self] in
            let audioURL = (try? await AppModel.offMainIO({ Self.readableRecordingURL(candidate) })) ?? nil
            self?.finishRecordingRestore(checkpoint, audioURL: audioURL)
        }
    }

    private func finishRecordingRestore(_ checkpoint: RecoveryCheckpoint, audioURL: URL?) {
        guard !checkpoint.segments.isEmpty || audioURL != nil else { return }
        let restored = Transcript(
            segments: checkpoint.segments,
            language: checkpoint.language ?? "en",
            modelName: checkpoint.modelName,
            sourceURL: audioURL,
            durationSeconds: checkpoint.segments.last?.end
        )
        clearDerivedArtifacts()
        selectedEntryID = nil
        pendingMediaDuration = nil
        if let audioURL {
            sourceFileURL = audioURL
            installPlayer(for: audioURL)
        } else {
            sourceFileURL = nil
            tearDownPlayer()
        }
        transcript = restored
        phase = .ready
        route = .transcript
        persistToLibrary(restored, audioSource: audioURL, title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt))
    }

    nonisolated static func readableRecordingURL(_ url: URL) -> URL? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return url
    }

    nonisolated static func recoveredRecordingTitle(startedAt: Date) -> String {
        "Recording \(startedAt.formatted(date: .abbreviated, time: .shortened)) (recovered)"
    }

    // MARK: - Inflight sweep

    var inflightRecordingsURL: URL {
        library.libraryURL.appendingPathComponent("inflight", isDirectory: true)
    }

    /// Deletes in-flight take files that nothing references anymore. Files under 48h
    /// stay: an active take is always younger, and a fresh orphan may still be wanted.
    func sweepInflightRecordings() {
        let dir = inflightRecordingsURL
        let keep = Set([pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
            .compactMap { $0?.standardizedFileURL.path })
        Task {
            try? await AppModel.offMainIO(qos: .utility, {
                let fm = FileManager.default
                guard let files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { return }
                let entries = files.map { url in
                    (url: url,
                     modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for stale in AppModel.staleInflightFiles(in: entries, keeping: keep, now: Date()) {
                    try? fm.removeItem(at: stale)
                }
            })
        }
    }

    nonisolated static func staleInflightFiles(
        in files: [(url: URL, modified: Date)],
        keeping: Set<String>,
        now: Date
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-48 * 3600)
        return files
            .filter { !keeping.contains($0.url.standardizedFileURL.path) && $0.modified < cutoff }
            .map(\.url)
    }
}
