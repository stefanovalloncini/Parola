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
    /// Nil in a file written before the field, which a restored take reads as a microphone take.
    var source: EntrySource?

    init(
        kind: Kind,
        startedAt: Date,
        modelName: String,
        sourceURL: URL? = nil,
        language: String? = nil,
        segments: [TranscriptSegment] = [],
        audioURL: URL? = nil,
        title: String? = nil,
        source: EntrySource? = nil
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.language = language
        self.segments = segments
        self.audioURL = audioURL
        self.title = title
        self.source = source
    }

    /// A file by its name; a link by the video's title, or the link itself before the title was known.
    var sourceName: String? {
        guard let sourceURL else { return nil }
        guard sourceURL.isFileURL else { return title ?? sourceURL.absoluteString }
        return sourceURL.lastPathComponent
    }
}

extension AppModel {

    var recoveryFileURL: URL {
        library.libraryURL.appendingPathComponent("recovery.json")
    }

    @discardableResult
    func beginFileTranscribeRecovery(sourceURL: URL, title: String? = nil, source: EntrySource = .file) -> Int {
        recoveryGeneration += 1
        activeRecoveryGeneration = recoveryGeneration
        recordingRecoveryStartedAt = nil
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .fileTranscription,
            startedAt: Date(),
            modelName: selectedModel,
            sourceURL: sourceURL,
            title: title,
            source: source
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
            audioURL: liveRecordingAudioURL,
            source: activeTake?.source.entrySource ?? pendingRecordingSource
        ))
    }

    /// Generation-guarded delete so a superseded task's exit can't remove its successor's file.
    func endRecovery(_ generation: Int) {
        guard generation == activeRecoveryGeneration else { return }
        endActiveRecovery()
    }

    /// Leaves a checkpoint a take's save still needs; that save ends it once the entry exists.
    func endActiveRecovery() {
        guard let active = activeRecoveryGeneration, !recoveryHeldBySave.contains(active) else { return }
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
            let data: Data
            do {
                data = try await AppModel.offMainIO { try JSONEncoder().encode(checkpoint) }
            } catch {
                ParolaLog.error(.appRecovery, "recovery checkpoint could not be encoded", [.error: .error(error)])
                return
            }
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
                await self.checkRecordingDiskSpace()
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
        ParolaLog.notice(
            .appRecovery, "recovery checkpoint offered for \(checkpoint.kind)",
            [.count: .int(checkpoint.segments.count)]
        )
        pendingRecovery = checkpoint
    }

    private nonisolated static func isRestorable(_ checkpoint: RecoveryCheckpoint) -> Bool {
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL else { return false }
            guard url.isFileURL else { return url.isYtDlpSupported }
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
            guard let url = checkpoint.sourceURL else { return }
            guard url.isFileURL else {
                transcribeYouTube(urlString: url.absoluteString)
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if let title = checkpoint.title {
                // A recorded take mid-transcription when the app died: the take path keeps
                // its title and saves the audio if this run fails too.
                fileTranscribeTask?.cancel()
                fileTranscribeTask = Task { [weak self] in
                    guard let self else { return }
                    await transcribeRecordedTake(url: url, title: title, source: checkpoint.source ?? .microphone)
                    if !Task.isCancelled { self.fileTranscribeTask = nil }
                }
            } else {
                transcribe(fileURL: url)
            }
        case .recording:
            restoreRecoveredRecording(checkpoint)
        }
    }

    /// Declining discards the take: its working file goes too, so the sweep doesn't bring it back.
    func declinePendingRecovery() {
        guard let checkpoint = pendingRecovery else { return }
        pendingRecovery = nil
        try? FileManager.default.removeItem(at: recoveryFileURL)
        for file in [checkpoint.audioURL, checkpoint.sourceURL].compactMap({ $0 }) where isInflightFile(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func restoreRecoveredRecording(_ checkpoint: RecoveryCheckpoint) {
        let pageAtStart = route
        guard let candidate = checkpoint.audioURL else {
            finishRecordingRestore(checkpoint, audioURL: nil, pageAtStart: pageAtStart)
            return
        }
        // A crash can leave the in-flight WAV with a stale header; attach it only
        // when it still opens, and probe off-main (AVAudioFile can block).
        Task { [weak self] in
            let audioURL = (try? await AppModel.offMainIO({ Self.readableRecordingURL(candidate) })) ?? nil
            self?.finishRecordingRestore(checkpoint, audioURL: audioURL, pageAtStart: pageAtStart)
        }
    }

    private func finishRecordingRestore(_ checkpoint: RecoveryCheckpoint, audioURL: URL?, pageAtStart: Route) {
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
        if let audioURL {
            sourceFileURL = audioURL
            installPlayer(for: audioURL)
        } else {
            sourceFileURL = nil
            tearDownPlayer()
        }
        transcript = restored
        if audioURL != nil { adoptLoadedMediaDuration() }
        phase = .ready
        // A page opened while the take was probed is the later word, as in loadEntry.
        if route == pageAtStart { route = .transcript }
        land(RunLanding(
            kind: .recording,
            transcript: restored,
            audioSource: audioURL,
            source: checkpoint.source ?? .microphone,
            category: takeRecordingCategory(),
            title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt)
        ))
    }

    nonisolated static func readableRecordingURL(_ url: URL) -> URL? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return url
    }

    nonisolated static func recoveredRecordingTitle(startedAt: Date, bundle: Bundle = .main) -> String {
        let title = liveRecordingTitle(category: .transcription, endedAt: startedAt, bundle: bundle)
        return "\(title) \(String(localized: "(recovered)", bundle: bundle))"
    }

    // MARK: - Inflight sweep

    var inflightRecordingsURL: URL {
        library.libraryURL.appendingPathComponent("inflight", isDirectory: true)
    }

    /// A take's working file, as opposed to a user's own file a recovery points at.
    func isInflightFile(_ file: URL) -> Bool {
        file.deletingLastPathComponent().resolvingSymlinksInPath().path
            == inflightRecordingsURL.resolvingSymlinksInPath().path
    }

    /// Whether this session still reads a working file: playing it, retrying it, recording it, transcribing it, or offering it back.
    func inflightFileInUse(_ file: URL) -> Bool {
        var readers = [sourceFileURL, failedTakeAudioURL, liveRecordingAudioURL, pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
        if takeRun != nil { readers.append(recordedTake?.file) }
        let path = file.resolvingSymlinksInPath().path
        return readers.contains { $0?.resolvingSymlinksInPath().path == path }
    }

    /// A take's working file goes once its entry holds the audio, unless something here still reads it.
    func releaseTakeFile(_ file: URL) {
        guard isInflightFile(file), !inflightFileInUse(file) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Copies of takes already in the library go; a take that never reached it comes back as a "(recovered)" entry.
    func sweepInflightRecordings() {
        let dir = inflightRecordingsURL
        let keep = Set([pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
            .compactMap { $0?.resolvingSymlinksInPath().path })
        inflightSweep = Task { [weak self, library] in
            let found = (try? await AppModel.offMainIO(qos: .utility) { AppModel.inflightFiles(in: dir) }) ?? []
            var recovered = 0
            var deleted = 0
            for file in AppModel.staleInflightFiles(in: found, keeping: keep, now: Date()) {
                if self?.inflightFileInUse(file) == true { continue }
                let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard bytes > AppModel.emptyTakeBytes else {
                    if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
                    continue
                }
                let digest = await SourceDigest.digest(of: file)
                if let digest, await library.hasEntry(digest: digest) {
                    if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
                    continue
                }
                let startedAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                do {
                    _ = try await library.add(
                        transcript: AppModel.untranscribedTranscript(of: file, language: nil),
                        audioSource: file,
                        category: .transcription,
                        title: AppModel.recoveredRecordingTitle(startedAt: startedAt),
                        sourceDigest: digest,
                        source: AppModel.inflightTakeSource(file),
                        consumesAudio: true
                    )
                    recovered += 1
                } catch {
                    ParolaLog.error(.appRecovery, "an orphaned take could not be brought back", [.error: .error(error)])
                }
            }
            if deleted > 0 {
                ParolaLog.notice(.appRecovery, "stale in-flight takes deleted", [.count: .int(deleted)])
            }
            if recovered > 0 {
                ParolaLog.notice(.appRecovery, "orphaned takes brought back", [.count: .int(recovered)])
                self?.refreshLibrary()
            }
        }
    }

    /// A WAV header and next to nothing after it: nothing was recorded.
    nonisolated static let emptyTakeBytes = 8_192

    nonisolated static func inflightFiles(in dir: URL) -> [(url: URL, modified: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.map { url in
            (url: url,
             modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    nonisolated static func inflightTakeSource(_ file: URL) -> EntrySource {
        file.lastPathComponent.hasPrefix("parola-system") ? .systemAudio : .microphone
    }

    /// Files left alone for ten minutes and not kept for a recovery offer; a take still writing is never that quiet.
    nonisolated static func staleInflightFiles(
        in files: [(url: URL, modified: Date)],
        keeping: Set<String>,
        now: Date
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-10 * 60)
        return files
            .filter { !keeping.contains($0.url.resolvingSymlinksInPath().path) && $0.modified < cutoff }
            .map(\.url)
    }
}
