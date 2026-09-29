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

    /// Names the checkpoint's file; one written before the field gets a fresh id when it is read.
    var id: UUID
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
        source: EntrySource? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
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

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        modelName = try c.decode(String.self, forKey: .modelName)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        source = try c.decodeIfPresent(EntrySource.self, forKey: .source)
    }

    /// A take by its title, a file by its name; a link by the video's title, or the link itself before the title was known.
    var sourceName: String? {
        guard let sourceURL else { return nil }
        guard sourceURL.isFileURL else { return title ?? sourceURL.absoluteString }
        return title ?? sourceURL.lastPathComponent
    }

    /// A recorded take rather than a file or link the user opened: its audio exists nowhere else.
    var isTake: Bool {
        kind == .recording || (title != nil && sourceURL?.isFileURL == true)
    }
}

extension AppModel {

    /// One file per take or run, so ending one never removes another's.
    var recoveryDirectoryURL: URL {
        library.libraryURL.appendingPathComponent("recovery", isDirectory: true)
    }

    /// Where the one checkpoint lived before each run had its own; a launch moves it into the directory.
    var legacyRecoveryFileURL: URL {
        library.libraryURL.appendingPathComponent("recovery.json")
    }

    func recoveryFileURL(for id: UUID) -> URL {
        recoveryDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// The checkpoint file of the run in flight, while there is one.
    var activeRecoveryFileURL: URL? {
        activeRecoveryGeneration.flatMap { recoveryFileIDs[$0] }.map(recoveryFileURL(for:))
    }

    /// Every checkpoint on disk, the legacy file included.
    var recoveryCheckpointFiles: [URL] {
        let listed = (try? FileManager.default.contentsOfDirectory(at: recoveryDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        let checkpoints = listed.filter { $0.pathExtension == "json" }
        guard FileManager.default.fileExists(atPath: legacyRecoveryFileURL.path) else { return checkpoints }
        return checkpoints + [legacyRecoveryFileURL]
    }

    @discardableResult
    func beginFileTranscribeRecovery(sourceURL: URL, title: String? = nil, source: EntrySource = .file) -> Int {
        let generation = beginRecoveryGeneration()
        recordingRecoveryStartedAt = nil
        writeRecoveryFile(RecoveryCheckpoint(
            kind: .fileTranscription,
            startedAt: Date(),
            modelName: selectedModel,
            sourceURL: sourceURL,
            title: title,
            source: source
        ))
        return generation
    }

    @discardableResult
    func beginRecordingRecovery() -> Int {
        let generation = beginRecoveryGeneration()
        recordingRecoveryStartedAt = Date()
        return generation
    }

    private func beginRecoveryGeneration() -> Int {
        recoveryGeneration += 1
        activeRecoveryGeneration = recoveryGeneration
        recoveryFileIDs[recoveryGeneration] = UUID()
        return recoveryGeneration
    }

    /// A checkpoint read at launch joins the live ones without becoming active, so the save that keeps its take can end it.
    func adoptRecovery(_ checkpoint: RecoveryCheckpoint) -> Int {
        recoveryGeneration += 1
        recoveryFileIDs[recoveryGeneration] = checkpoint.id
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

    /// Deletes that run's checkpoint unless a take's run or save still needs it; other runs' checkpoints stay.
    func endRecovery(_ generation: Int) {
        guard !recoveryHeldByTake.contains(generation) else { return }
        if generation == activeRecoveryGeneration {
            activeRecoveryGeneration = nil
            recordingRecoveryStartedAt = nil
        }
        guard let id = recoveryFileIDs.removeValue(forKey: generation) else { return }
        let url = recoveryFileURL(for: id)
        // Synchronous on the same queue the writes use: a checkpoint already queued must land
        // before this delete, or it resurrects the prompt after the recording stopped.
        recoveryFileQueue.sync { try? FileManager.default.removeItem(at: url) }
    }

    func endActiveRecovery() {
        guard let active = activeRecoveryGeneration else { return }
        endRecovery(active)
    }

    private func writeRecoveryFile(_ checkpoint: RecoveryCheckpoint) {
        guard let generation = activeRecoveryGeneration, let id = recoveryFileIDs[generation] else { return }
        var checkpoint = checkpoint
        checkpoint.id = id
        let url = recoveryFileURL(for: id)
        let directory = recoveryDirectoryURL
        pendingRecoveryWrite = Task { [weak self, checkpoint] in
            let data: Data
            do {
                data = try await AppModel.offMainIO { try JSONEncoder().encode(checkpoint) }
            } catch {
                ParolaLog.error(.appRecovery, "recovery checkpoint could not be encoded", [.error: .error(error)])
                return
            }
            // Re-check after the encode: the run may have ended meanwhile, and a late
            // write would resurrect a stale recovery prompt on the next launch.
            guard let self, self.recoveryFileIDs[generation] == id else { return }
            // Queued in the same main-actor step as the check above, so an endRecovery
            // that lands after it still drains this write before deleting the file.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recoveryFileQueue.async {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    /// Offers the newest checkpoint; older takes go to the library quietly, and older file offers lapse.
    func loadPendingRecovery() {
        var found: [RecoveryCheckpoint] = []
        for file in recoveryCheckpointFiles {
            guard let data = try? Data(contentsOf: file),
                  let checkpoint = try? JSONDecoder().decode(RecoveryCheckpoint.self, from: data),
                  Self.isRestorable(checkpoint) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            settleCheckpointFile(checkpoint, at: file)
            found.append(checkpoint)
        }
        recoveryReferencedFiles = Set(found.flatMap { [$0.sourceURL, $0.audioURL] }
            .compactMap { $0?.isFileURL == true ? $0?.resolvingSymlinksInPath().path : nil })
        guard let newest = found.max(by: { $0.startedAt < $1.startedAt }) else { return }
        for older in found where older.id != newest.id {
            keepRecoveredTake(older, releasingReferencesWhenSaved: true)
        }
        ParolaLog.notice(
            .appRecovery, "recovery checkpoint offered for \(newest.kind)",
            [.count: .int(newest.segments.count)]
        )
        pendingRecovery = newest
    }

    /// A checkpoint whose file isn't named for it, the legacy recovery.json among them, moves under its own name.
    private func settleCheckpointFile(_ checkpoint: RecoveryCheckpoint, at file: URL) {
        let target = recoveryFileURL(for: checkpoint.id)
        guard file.standardizedFileURL.path != target.standardizedFileURL.path else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(checkpoint).write(to: target, options: .atomic)
            try FileManager.default.removeItem(at: file)
        } catch {
            ParolaLog.error(.appRecovery, "a recovery checkpoint could not be moved", [.error: .error(error)])
        }
    }

    /// The offer is answered: what it points at is no longer held back from the sweep or from release.
    private func answerRecoveryOffer(_ checkpoint: RecoveryCheckpoint) {
        pendingRecovery = nil
        recoveryReferencedFiles.subtract([checkpoint.sourceURL, checkpoint.audioURL].compactMap { $0?.resolvingSymlinksInPath().path })
    }

    /// The offer is settled: its own file goes, whatever else is on disk.
    func removeRecoveryFile(of checkpoint: RecoveryCheckpoint) {
        let url = recoveryFileURL(for: checkpoint.id)
        recoveryFileQueue.sync { try? FileManager.default.removeItem(at: url) }
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
        answerRecoveryOffer(checkpoint)
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL else {
                removeRecoveryFile(of: checkpoint)
                return
            }
            guard url.isFileURL else {
                removeRecoveryFile(of: checkpoint)
                transcribeYouTube(urlString: url.absoluteString)
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                removeRecoveryFile(of: checkpoint)
                return
            }
            if let title = checkpoint.title {
                // A recorded take mid-transcription when the app died: the take path keeps
                // its title and saves the audio if this run fails too.
                let adopted = adoptRecovery(checkpoint)
                startTakeTask { [weak self] in
                    await self?.transcribeRecordedTake(
                        url: url, title: title, source: checkpoint.source ?? .microphone, replacing: adopted
                    )
                }
            } else {
                removeRecoveryFile(of: checkpoint)
                transcribe(fileURL: url)
            }
        case .recording:
            restoreRecoveredRecording(checkpoint)
        }
    }

    /// Not Now, Escape or a prompt closed unanswered: a take is kept in the library, a file or link is simply not offered again.
    func declinePendingRecovery() {
        guard let checkpoint = pendingRecovery else { return }
        answerRecoveryOffer(checkpoint)
        keepRecoveredTake(checkpoint, releasingReferencesWhenSaved: false)
    }

    /// The prompt's Discard, once confirmed: the only answer that deletes a take.
    func discardPendingRecovery() {
        guard let checkpoint = pendingRecovery else { return }
        answerRecoveryOffer(checkpoint)
        removeRecoveryFile(of: checkpoint)
        for file in [checkpoint.audioURL, checkpoint.sourceURL].compactMap({ $0 }) where isInflightFile(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Saves a take without opening it; its checkpoint goes once the entry exists, and a file or link's offer just lapses.
    private func keepRecoveredTake(_ checkpoint: RecoveryCheckpoint, releasingReferencesWhenSaved: Bool) {
        guard checkpoint.isTake else {
            removeRecoveryFile(of: checkpoint)
            return
        }
        let referenced = [checkpoint.sourceURL, checkpoint.audioURL].compactMap { $0?.resolvingSymlinksInPath().path }
        var release: (@MainActor (LibraryEntry) -> Void)?
        if releasingReferencesWhenSaved {
            release = { [weak self] _ in self?.recoveryReferencedFiles.subtract(referenced) }
        }
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL, let title = checkpoint.title,
                  FileManager.default.fileExists(atPath: url.path) else {
                removeRecoveryFile(of: checkpoint)
                return
            }
            saveTake(
                Self.untranscribedTranscript(of: url, language: checkpoint.language),
                audio: url,
                title: Self.takeTitle(title, suffix: .notTranscribed),
                source: checkpoint.source ?? .microphone,
                category: .transcription,
                activate: false,
                recovery: adoptRecovery(checkpoint),
                onSaved: release
            )
        case .recording:
            Task { [weak self] in
                let audioURL = await Self.probedRecordingURL(checkpoint.audioURL)
                guard let self else { return }
                guard let restored = Self.restoredTranscript(checkpoint, audioURL: audioURL) else {
                    self.removeRecoveryFile(of: checkpoint)
                    return
                }
                self.saveTake(
                    restored,
                    audio: audioURL,
                    title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt),
                    source: checkpoint.source ?? .microphone,
                    category: .transcription,
                    activate: false,
                    recovery: self.adoptRecovery(checkpoint),
                    onSaved: release
                )
            }
        }
    }

    private func restoreRecoveredRecording(_ checkpoint: RecoveryCheckpoint) {
        let pageAtStart = route
        guard checkpoint.audioURL != nil else {
            finishRecordingRestore(checkpoint, audioURL: nil, pageAtStart: pageAtStart)
            return
        }
        Task { [weak self] in
            let audioURL = await Self.probedRecordingURL(checkpoint.audioURL)
            self?.finishRecordingRestore(checkpoint, audioURL: audioURL, pageAtStart: pageAtStart)
        }
    }

    /// A crash can leave the in-flight WAV with a stale header, so a take's audio is attached only when it still opens; probed off-main, since AVAudioFile can block.
    private nonisolated static func probedRecordingURL(_ candidate: URL?) async -> URL? {
        guard let candidate else { return nil }
        return (try? await AppModel.offMainIO { Self.readableRecordingURL(candidate) }) ?? nil
    }

    /// What a recording checkpoint holds as a transcript; nil when it holds nothing at all.
    nonisolated static func restoredTranscript(_ checkpoint: RecoveryCheckpoint, audioURL: URL?) -> Transcript? {
        guard !checkpoint.segments.isEmpty || audioURL != nil else { return nil }
        return Transcript(
            segments: checkpoint.segments,
            language: checkpoint.language ?? "en",
            modelName: checkpoint.modelName,
            sourceURL: audioURL,
            durationSeconds: checkpoint.segments.last?.end
        )
    }

    private func finishRecordingRestore(_ checkpoint: RecoveryCheckpoint, audioURL: URL?, pageAtStart: Route) {
        guard let restored = Self.restoredTranscript(checkpoint, audioURL: audioURL) else {
            removeRecoveryFile(of: checkpoint)
            return
        }
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
        saveTake(
            restored,
            audio: audioURL,
            title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt),
            source: checkpoint.source ?? .microphone,
            category: .transcription,
            activate: true,
            recovery: adoptRecovery(checkpoint)
        )
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
        let path = file.resolvingSymlinksInPath().path
        if recoveryReferencedFiles.contains(path) { return true }
        var readers = [sourceFileURL, failedTakeAudioURL, liveRecordingAudioURL, pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
        if takeRun != nil { readers.append(recordedTake?.file) }
        return readers.contains { $0?.resolvingSymlinksInPath().path == path }
    }

    /// A take's working file goes once its entry holds the audio, unless something here still reads it.
    func releaseTakeFile(_ file: URL) {
        guard isInflightFile(file), !inflightFileInUse(file) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Copies of takes already in the library go, and so does old scratch; a take that never reached the library comes back as a "(recovered)" entry.
    func sweepInflightRecordings() {
        let dir = inflightRecordingsURL
        let keep = recoveryReferencedFiles.union([pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
            .compactMap { $0?.resolvingSymlinksInPath().path })
        inflightSweep = Task { [weak self, library] in
            let found = (try? await AppModel.offMainIO(qos: .utility) { AppModel.inflightFiles(in: dir) }) ?? []
            var recovered = 0
            var deleted = 0
            for file in AppModel.staleInflightFiles(in: found, keeping: keep, now: Date()) {
                if self?.inflightFileInUse(file) == true { continue }
                let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard RecordingScratch.isTake(file), bytes > AppModel.emptyTakeBytes else {
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

    /// The regular .wav files in the folder; anything else there is left alone.
    nonisolated static func inflightFiles(in dir: URL) -> [(url: URL, modified: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url: url, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    nonisolated static func inflightTakeSource(_ file: URL) -> EntrySource {
        file.lastPathComponent.hasPrefix("parola-system") ? .systemAudio : .microphone
    }

    /// Files not kept for a recovery offer and quiet long enough: a take after ten minutes, which one still writing never is, and other scratch after two days.
    nonisolated static func staleInflightFiles(
        in files: [(url: URL, modified: Date)],
        keeping: Set<String>,
        now: Date
    ) -> [URL] {
        files
            .filter { file in
                guard !keeping.contains(file.url.resolvingSymlinksInPath().path) else { return false }
                let quiet: TimeInterval = RecordingScratch.isTake(file.url) ? 10 * 60 : 48 * 3600
                return file.modified < now.addingTimeInterval(-quiet)
            }
            .map(\.url)
    }
}
