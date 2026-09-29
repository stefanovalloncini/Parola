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
    /// Nil in a file written before the field, which a restored take files as a transcription.
    var category: EntryCategory?
    /// The instance that wrote it; nil in a file from a build before owners, which a launch judges by how recently its take was written.
    var owner: String?

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
        category: EntryCategory? = nil,
        owner: String? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.category = category
        self.owner = owner
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
        category = try c.decodeIfPresent(EntryCategory.self, forKey: .category)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
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

    /// The files on disk it points at, as resolved paths.
    var referencedPaths: [String] {
        [sourceURL, audioURL].compactMap { $0?.isFileURL == true ? $0?.resolvingSymlinksInPath().path : nil }
    }
}

extension AppModel {

    /// One file per take or run, so ending one never removes another's.
    var recoveryDirectoryURL: URL {
        library.libraryURL.appendingPathComponent("recovery", isDirectory: true)
    }

    /// Where each running instance keeps the lock that says its checkpoints are live.
    var recoveryOwnersDirectoryURL: URL {
        recoveryDirectoryURL.appendingPathComponent("owners", isDirectory: true)
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
    func beginFileTranscribeRecovery(
        sourceURL: URL, title: String? = nil, source: EntrySource = .file, category: EntryCategory? = nil
    ) -> Int {
        let generation = beginRecoveryGeneration()
        recordingRecoveryStartedAt = nil
        writeRecoveryFile(generation: generation, RecoveryCheckpoint(
            kind: .fileTranscription,
            startedAt: Date(),
            modelName: selectedModel,
            sourceURL: sourceURL,
            title: title,
            source: source,
            category: category
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
        let generation = activeTake.map(\.recovery) ?? activeRecoveryGeneration
        let startedAt = activeTake.map(\.recoveryStartedAt) ?? recordingRecoveryStartedAt
        guard let generation, let startedAt else { return }
        guard !liveSegments.isEmpty || liveRecordingAudioURL != nil else { return }
        writeRecoveryFile(generation: generation, RecoveryCheckpoint(
            kind: .recording,
            startedAt: startedAt,
            modelName: selectedModel,
            language: selectedLanguage,
            segments: liveSegments,
            audioURL: liveRecordingAudioURL,
            source: activeTake?.source.entrySource ?? pendingRecordingSource,
            category: activeTake?.category
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
        deleteCheckpointFiles(id)
    }

    /// Deletes a checkpoint under its own name and wherever it was read from, so a move that failed can't keep it alive.
    private func deleteCheckpointFiles(_ id: UUID) {
        let files = [recoveryFileURL(for: id), recoveryLoadedFiles.removeValue(forKey: id)].compactMap { $0 }
        // Synchronous on the same queue the writes use: a checkpoint already queued must land
        // before this delete, or it resurrects the prompt after the recording stopped.
        recoveryFileQueue.sync {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func endActiveRecovery() {
        guard let active = activeRecoveryGeneration else { return }
        endRecovery(active)
    }

    /// A take whose save failed: its checkpoint stays for the next launch, out of reach of the cleanup the next take runs.
    func keepForNextLaunch(_ generation: Int) {
        guard generation == activeRecoveryGeneration else { return }
        activeRecoveryGeneration = nil
        recordingRecoveryStartedAt = nil
    }

    private func writeRecoveryFile(generation: Int, _ checkpoint: RecoveryCheckpoint) {
        guard let id = recoveryFileIDs[generation] else { return }
        var checkpoint = checkpoint
        checkpoint.id = id
        checkpoint.owner = recoveryOwner?.id
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

    /// Offers the newest checkpoint an instance left behind; older takes go to the library quietly, and a running instance's are left alone.
    func loadPendingRecovery() {
        let owners = recoveryOwnersDirectoryURL
        RecoveryOwner.removeDeadLocks(in: owners)
        var found: [RecoveryCheckpoint] = []
        var live = Set<String>()
        for file in recoveryCheckpointFiles {
            guard let data = try? Data(contentsOf: file),
                  let checkpoint = try? JSONDecoder().decode(RecoveryCheckpoint.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let owner = checkpoint.owner, owner != recoveryOwner?.id, RecoveryOwner.isAlive(owner, in: owners) {
                live.formUnion(checkpoint.referencedPaths)
                continue
            }
            // Written by a build before owners: a take written in the last two minutes may still be recording there.
            if checkpoint.owner == nil, isStillBeingWritten(checkpoint, now: Date()) {
                live.formUnion(checkpoint.referencedPaths)
                continue
            }
            guard Self.isRestorable(checkpoint) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            var claimed = checkpoint
            claimed.owner = recoveryOwner?.id
            settleCheckpointFile(claimed, at: file)
            found.append(claimed)
        }
        found = collapsingShared(found)
        recoveryReferencedFiles = live.union(found.flatMap(\.referencedPaths))
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

    /// Checkpoints that point at the same file, a take's capture and its transcription say, come down to the newest.
    private func collapsingShared(_ checkpoints: [RecoveryCheckpoint]) -> [RecoveryCheckpoint] {
        var newest: [String: RecoveryCheckpoint] = [:]
        var kept: [RecoveryCheckpoint] = []
        for checkpoint in checkpoints.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let file = checkpoint.referencedPaths.first else {
                kept.append(checkpoint)
                continue
            }
            if newest[file] == nil {
                newest[file] = checkpoint
                kept.append(checkpoint)
            } else {
                removeRecoveryFile(of: checkpoint)
            }
        }
        return kept
    }

    /// The entry already holding these exact bytes, when a crash came after the save but before its checkpoint went.
    func entryHolding(_ audio: URL) async -> LibraryEntry? {
        guard let digest = await SourceDigest.digest(of: audio) else { return nil }
        return await library.findEntry(digest: digest)
    }

    /// Whether the library, Recently Deleted included, already holds these exact bytes.
    func libraryHolds(_ audio: URL) async -> Bool {
        guard let digest = await SourceDigest.digest(of: audio) else { return false }
        return await library.hasEntry(digest: digest)
    }

    /// A take's working file written in the last two minutes: a live recording, as far as a checkpoint with no owner can tell.
    private func isStillBeingWritten(_ checkpoint: RecoveryCheckpoint, now: Date) -> Bool {
        checkpoint.referencedPaths.contains { path in
            let url = URL(fileURLWithPath: path)
            guard isInflightFile(url),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return modified > now.addingTimeInterval(-2 * 60)
        }
    }

    /// Claims a checkpoint for this instance, under its own name: the legacy recovery.json moves into the directory.
    private func settleCheckpointFile(_ checkpoint: RecoveryCheckpoint, at file: URL) {
        let target = recoveryFileURL(for: checkpoint.id)
        if file.standardizedFileURL.path != target.standardizedFileURL.path { recoveryLoadedFiles[checkpoint.id] = file }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(checkpoint).write(to: target, options: .atomic)
            if file.standardizedFileURL.path != target.standardizedFileURL.path {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            ParolaLog.error(.appRecovery, "a recovery checkpoint could not be moved", [.error: .error(error)])
        }
    }

    /// The offer is answered: what it points at is no longer held back from the sweep or from release.
    private func answerRecoveryOffer(_ checkpoint: RecoveryCheckpoint) {
        pendingRecovery = nil
        recoveryReferencedFiles.subtract(checkpoint.referencedPaths)
    }

    /// The offer is settled: its own file goes, whatever else is on disk.
    func removeRecoveryFile(of checkpoint: RecoveryCheckpoint) {
        deleteCheckpointFiles(checkpoint.id)
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
        // Restoring takes over the screen a take in progress is using; the offer waits until the take ends.
        guard !recordingActive else {
            exportNotice = ExportNotice(
                message: String(localized: "Finish the recording first. Parola offers the recovered one again when it ends."),
                failures: [],
                folder: nil
            )
            return
        }
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
                Task { [weak self] in
                    guard let self else { return }
                    if let entry = await self.entryHolding(url) {
                        self.removeRecoveryFile(of: checkpoint)
                        await self.openRecoveredEntry(entry)
                        return
                    }
                    let adopted = self.adoptRecovery(checkpoint)
                    self.startTakeTask { [weak self] in
                        await self?.transcribeRecordedTake(
                            url: url, title: title, source: checkpoint.source ?? .microphone,
                            category: checkpoint.category ?? .transcription, replacing: adopted
                        )
                    }
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
        let referenced = checkpoint.referencedPaths
        var release: (@MainActor (LibraryEntry) -> Void)?
        if releasingReferencesWhenSaved {
            release = { [weak self] _ in self?.recoveryReferencedFiles.subtract(referenced) }
        }
        let alreadySaved: @MainActor () -> Void = { [weak self] in
            self?.removeRecoveryFile(of: checkpoint)
            if releasingReferencesWhenSaved { self?.recoveryReferencedFiles.subtract(referenced) }
        }
        switch checkpoint.kind {
        case .fileTranscription:
            guard let url = checkpoint.sourceURL, let title = checkpoint.title,
                  FileManager.default.fileExists(atPath: url.path) else {
                removeRecoveryFile(of: checkpoint)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                guard await !self.libraryHolds(url) else { return alreadySaved() }
                self.saveTake(
                    Self.untranscribedTranscript(of: url, language: checkpoint.language),
                    audio: url,
                    title: Self.takeTitle(title, suffix: .notTranscribed),
                    source: checkpoint.source ?? .microphone,
                    category: checkpoint.category ?? .transcription,
                    activate: false,
                    recovery: self.adoptRecovery(checkpoint),
                    onSaved: release
                )
            }
        case .recording:
            Task { [weak self] in
                let audioURL = await Self.probedRecordingURL(checkpoint.audioURL)
                guard let self else { return }
                if let audioURL, await self.libraryHolds(audioURL) { return alreadySaved() }
                guard let restored = Self.restoredTranscript(checkpoint, audioURL: audioURL) else {
                    self.removeRecoveryFile(of: checkpoint)
                    return
                }
                self.saveTake(
                    restored,
                    audio: audioURL,
                    title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt, category: checkpoint.category ?? .transcription),
                    source: checkpoint.source ?? .microphone,
                    category: checkpoint.category ?? .transcription,
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
            guard let self else { return }
            if let audioURL, let entry = await self.entryHolding(audioURL) {
                self.removeRecoveryFile(of: checkpoint)
                await self.openRecoveredEntry(entry)
                return
            }
            self.finishRecordingRestore(checkpoint, audioURL: audioURL, pageAtStart: pageAtStart)
        }
    }

    /// A recovered take that already has its entry opens that entry, and one saved as audio alone gets transcribed there.
    private func openRecoveredEntry(_ entry: LibraryEntry) async {
        guard (try? await openEntry(entry.id)) != nil else { return }
        if transcriptIsUntranscribed { transcribeLoadedEntry() }
    }

    /// A crash can leave the in-flight WAV with a stale header, so a take's audio is attached only when it still opens; probed off-main, since AVAudioFile can block.
    private nonisolated static func probedRecordingURL(_ candidate: URL?) async -> URL? {
        guard let candidate else { return nil }
        return (try? await AppModel.offMainIO { Self.readableRecordingURL(candidate) }) ?? nil
    }

    /// What a recording checkpoint holds as a transcript, not transcribed when no words came through; nil when it holds nothing at all.
    nonisolated static func restoredTranscript(_ checkpoint: RecoveryCheckpoint, audioURL: URL?) -> Transcript? {
        guard !checkpoint.segments.isEmpty || audioURL != nil else { return nil }
        return Transcript(
            segments: checkpoint.segments,
            language: checkpoint.language ?? "en",
            modelName: checkpoint.segments.isEmpty ? "" : checkpoint.modelName,
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
            title: Self.recoveredRecordingTitle(startedAt: checkpoint.startedAt, category: checkpoint.category ?? .transcription),
            source: checkpoint.source ?? .microphone,
            category: checkpoint.category ?? .transcription,
            activate: true,
            recovery: adoptRecovery(checkpoint)
        )
    }

    nonisolated static func readableRecordingURL(_ url: URL) -> URL? {
        WAVHeaderRepair.makeReadable(url) ? url : nil
    }

    nonisolated static func recoveredRecordingTitle(
        startedAt: Date, category: EntryCategory = .transcription, bundle: Bundle = .main
    ) -> String {
        let title = liveRecordingTitle(category: category, endedAt: startedAt, bundle: bundle)
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

    /// The working files this session still reads: playing, retrying, recording, transcribing, saving, or offering one back.
    var inflightFilesInUse: Set<String> {
        var readers = [sourceFileURL, failedTakeAudioURL, liveRecordingAudioURL, pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
        if takeRun != nil { readers.append(recordedTake?.file) }
        let paths = (readers.compactMap { $0 } + takeFilesBeingSaved.keys).map { $0.resolvingSymlinksInPath().path }
        return recoveryReferencedFiles.union(paths)
    }

    func inflightFileInUse(_ file: URL) -> Bool {
        inflightFilesInUse.contains(file.resolvingSymlinksInPath().path)
    }

    /// Once a minute, marks the working files in use as just written, so no instance's sweep, this one's or another's, takes them.
    func startTakeFileHeartbeat() {
        takeFileHeartbeat?.cancel()
        let clock = clock
        takeFileHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled, self != nil {
                self?.touchTakeFilesInUse()
                try? await Task.sleep(for: .seconds(60), clock: clock)
            }
        }
    }

    func touchTakeFilesInUse() {
        let now = Date()
        for path in inflightFilesInUse where isInflightFile(URL(fileURLWithPath: path)) {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
        }
    }

    /// A take's working file goes once its entry holds the audio, unless something here still reads it.
    func releaseTakeFile(_ file: URL) {
        guard isInflightFile(file), !inflightFileInUse(file) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Copies of takes already in the library go, and so does old scratch; a take that never reached the library comes back as a "(recovered)" entry.
    func sweepInflightRecordings() {
        let dir = inflightRecordingsURL
        let root = library.libraryURL
        let keep = recoveryReferencedFiles.union([pendingRecovery?.sourceURL, pendingRecovery?.audioURL]
            .compactMap { $0?.resolvingSymlinksInPath().path })
        let cutoff = takeImportCutoff()
        inflightSweep = Task { [weak self, library] in
            let found = (try? await AppModel.offMainIO(qos: .utility) { AppModel.inflightFiles(in: dir) }) ?? []
            var recovered = 0
            var deleted = 0
            let modified = Dictionary(found.map { ($0.url, $0.modified) }, uniquingKeysWith: { first, _ in first })
            for file in AppModel.staleInflightFiles(in: found, keeping: keep, now: Date(), takesSince: cutoff) {
                if self?.inflightFileInUse(file) == true { continue }
                let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let isTake = AppModel.isImportableTake(file, modified: modified[file] ?? .distantPast, takesSince: cutoff)
                guard isTake, bytes > AppModel.emptyTakeBytes else {
                    if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
                    continue
                }
                // A take cut off by a crash may still carry the sizes its writer opened with.
                _ = try? await AppModel.offMainIO(qos: .utility) { WAVHeaderRepair.makeReadable(file) }
                let digest = await SourceDigest.digest(of: file)
                if let digest, await library.hasEntry(digest: digest) {
                    if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
                    continue
                }
                let startedAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                do {
                    // Copied, not moved: the original goes only once the entry holds the audio.
                    _ = try await library.add(
                        transcript: AppModel.untranscribedTranscript(of: file, language: nil),
                        audioSource: file,
                        category: .transcription,
                        title: AppModel.recoveredRecordingTitle(startedAt: startedAt),
                        sourceDigest: digest,
                        source: AppModel.inflightTakeSource(file)
                    )
                    recovered += 1
                    if self?.inflightFileInUse(file) != true { try? FileManager.default.removeItem(at: file) }
                } catch {
                    ParolaLog.error(.appRecovery, "an orphaned take could not be brought back", [.error: .error(error)])
                }
            }
            let staging = (try? await AppModel.offMainIO(qos: .utility) { AppModel.staleStagingFolders(in: root, now: Date()) }) ?? []
            for folder in staging where await AppModel.salvageStagingFolder(folder, into: library) {
                recovered += 1
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

    /// The `.parola.tmp` folders a save left in the library when it was cut off, once ten minutes quiet, contents included.
    nonisolated static func staleStagingFolders(in root: URL, now: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let listed = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return listed.filter { url in
            guard url.lastPathComponent.hasSuffix(".parola.tmp"),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return false }
            return newestModification(in: url, besides: values.contentModificationDate) < now.addingTimeInterval(-10 * 60)
        }
    }

    /// A copy into the folder moves its file's date, not the folder's, so the newest of them says when the folder was last written.
    private nonisolated static func newestModification(in folder: URL, besides folderDate: Date?) -> Date {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let dates = contents.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return (dates + [folderDate ?? .distantPast]).max() ?? .distantPast
    }

    /// Whatever a cut-off save's folder holds becomes an entry, the whole document if it was complete; the folder goes only once the entry exists.
    nonisolated static func salvageStagingFolder(_ folder: URL, into library: LibraryStore) async -> Bool {
        let fm = FileManager.default
        let staged = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("audio.") })
        if let staged, let digest = await SourceDigest.digest(of: staged), await library.hasEntry(digest: digest) {
            try? fm.removeItem(at: folder)
            return false
        }
        let entry: LibraryEntry?
        if let document = try? ParolaDocument.read(at: folder) {
            entry = try? await library.add(
                transcript: document.transcript,
                audioSource: document.audioURL,
                category: document.manifest.category,
                title: document.manifest.title,
                titleSource: document.manifest.titleSource,
                source: document.manifest.source
            )
        } else if let audio = staged {
            let startedAt = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            entry = try? await library.add(
                transcript: untranscribedTranscript(of: audio, language: nil),
                audioSource: audio,
                title: recoveredRecordingTitle(startedAt: startedAt)
            )
        } else {
            try? fm.removeItem(at: folder)
            return false
        }
        guard entry != nil else {
            ParolaLog.error(.appRecovery, "a save cut off mid-write could not be brought back")
            return false
        }
        try? fm.removeItem(at: folder)
        return true
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

    /// When this build first swept the library; an earlier build's dictation left parola-mic files too, so older ones stay scratch.
    func takeImportCutoff() -> Date {
        let marker = recoveryDirectoryURL.appendingPathComponent("take-import-cutoff")
        let format = ISO8601DateFormatter()
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let date = format.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date
        }
        let now = Date()
        try? FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
        try? format.string(from: now).write(to: marker, atomically: true, encoding: .utf8)
        return now
    }

    /// A take the sweep may bring back: any take prefix, but a parola-mic file only if it was written after the cutoff.
    nonisolated static func isImportableTake(_ file: URL, modified: Date, takesSince cutoff: Date) -> Bool {
        guard RecordingScratch.isTake(file) else { return false }
        return !file.lastPathComponent.hasPrefix("parola-mic-") || modified >= cutoff
    }

    nonisolated static func inflightTakeSource(_ file: URL) -> EntrySource {
        file.lastPathComponent.hasPrefix("parola-system") ? .systemAudio : .microphone
    }

    /// Files not kept for a recovery offer and quiet long enough: a take after ten minutes, which one still writing never is, and other scratch after two days.
    nonisolated static func staleInflightFiles(
        in files: [(url: URL, modified: Date)],
        keeping: Set<String>,
        now: Date,
        takesSince cutoff: Date = .distantPast
    ) -> [URL] {
        files
            .filter { file in
                guard !keeping.contains(file.url.resolvingSymlinksInPath().path) else { return false }
                let quiet: TimeInterval = isImportableTake(file.url, modified: file.modified, takesSince: cutoff) ? 10 * 60 : 48 * 3600
                return file.modified < now.addingTimeInterval(-quiet)
            }
            .map(\.url)
    }
}
