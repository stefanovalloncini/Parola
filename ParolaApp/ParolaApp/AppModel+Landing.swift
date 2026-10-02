import Foundation
import os
import ParolaCore

/// A finished run on its way into the library. Every run lands through `AppModel.land(_:)`.
struct RunLanding {
    enum Kind: CaseIterable, Sendable {
        case file
        case link
        case recording
        /// A take that failed or was cut short: saved so it survives, and nothing more.
        case salvagedTake
        case subtitles
        case captions
        case batchJob
        /// An entry's own audio run again: the result replaces what the entry held.
        case rerun
        /// A take's Retry after its transcription failed: it replaces the entry its failure saved, and is delivered as the take would have been.
        case retriedTake
        /// A watched-folder file that arrived while Parola was idle, run where the user can see it.
        case arrival
        /// A watched-folder file run out of sight while the user works on something else.
        case backgroundArrival
        /// A take that finished while another page showed: delivered as a take is, with a toast instead of the screen.
        case backgroundTake
        /// A file or link run that finished after the user opened something else or went to another page: a toast instead of the screen.
        case backgroundRun
    }

    let kind: Kind
    let transcript: Transcript
    var audioSource: URL?
    var source: EntrySource = .file
    var category: EntryCategory = .transcription
    var title: String?
    var titleSource: TitleSource?
    /// A take's markers, kept in its entry so every transcript it gets makes their sentences favorites.
    var takeMarkers: [TimeInterval] = []
    var sourceDigest: String?
    var consumesAudio = false
    /// The job a `.batchJob` landing finishes.
    var batchJobID: BatchJob.ID?
    /// The entry a `.rerun` replaces, and the notes it held on the old segments.
    var rerunEntryID: LibraryEntry.ID?
    var clearingNotes: [String: String] = [:]

    var policy: LandingPolicy { kind.policy }

    static func batchJob(_ job: BatchJob, transcript: Transcript) -> RunLanding {
        RunLanding(
            kind: .batchJob, transcript: transcript, audioSource: job.url,
            sourceDigest: job.sourceDigest, batchJobID: job.id
        )
    }

    static func rerun(of entryID: LibraryEntry.ID, transcript: Transcript, clearingNotes: [String: String]) -> RunLanding {
        RunLanding(kind: .rerun, transcript: transcript, rerunEntryID: entryID, clearingNotes: clearingNotes)
    }
}

/// What a landing does once the run is saved. One row per kind of run, and nothing else decides.
struct LandingPolicy: Equatable, Sendable {
    enum Selection: Equatable, Sendable {
        case none
        /// The saved entry takes the selection, unless the user opened something else while it saved.
        case unlessNavigated
        /// The batch job's copy, if it is still on screen, becomes the entry; the list waits for the batch's last add.
        case batchCopy
        /// The entry keeps the selection it had, and shows the new transcript if it is open.
        case keep
    }

    enum Summary: Equatable, Sendable {
        case never
        /// The autostart rule, for an entry that took the selection.
        case whenSelected
        /// The autostart rule, whatever is on screen.
        case always
    }

    enum Export: Equatable, Sendable {
        case none
        /// The auto-export rules: beside a file, or in the chosen folder for takes and links.
        case rules
        /// The batch's presets beside the file, planned together with the rules.
        case batchPresets
    }

    var selection: Selection
    var sound: Bool
    var card: Bool
    var summary: Summary
    var export: Export
    var autoSend: Bool
    /// The file goes into Open Recent when its run starts.
    var recents: Bool
    /// A toast says the entry landed, and opens it.
    var announces = false
}

extension RunLanding.Kind {
    var policy: LandingPolicy {
        switch self {
        case .file:
            LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: true
            )
        case .link, .recording:
            LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            )
        case .subtitles:
            LandingPolicy(
                selection: .unlessNavigated, sound: false, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: true
            )
        case .captions:
            LandingPolicy(
                selection: .unlessNavigated, sound: false, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            )
        case .salvagedTake:
            LandingPolicy(
                selection: .none, sound: false, card: false, summary: .never,
                export: .none, autoSend: false, recents: false
            )
        case .batchJob:
            // The run rings once when it ends, not once per file.
            LandingPolicy(
                selection: .batchCopy, sound: false, card: true, summary: .never,
                export: .batchPresets, autoSend: false, recents: false
            )
        case .rerun:
            LandingPolicy(
                selection: .keep, sound: true, card: true, summary: .never,
                export: .none, autoSend: false, recents: false
            )
        case .retriedTake:
            LandingPolicy(
                selection: .keep, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            )
        case .arrival:
            LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            )
        case .backgroundArrival:
            // The lane rings once when it runs dry, not once per file.
            LandingPolicy(
                selection: .none, sound: false, card: true, summary: .always,
                export: .rules, autoSend: true, recents: false, announces: true
            )
        case .backgroundTake, .backgroundRun:
            LandingPolicy(
                selection: .none, sound: true, card: true, summary: .always,
                export: .rules, autoSend: true, recents: false, announces: true
            )
        }
    }
}

extension AppModel {

    /// Each main-actor turn a finished run lands in: the install, the saved entry, the AI card.
    static let landingSignposter = OSSignposter(subsystem: "app.parola.app", category: "landing")

    /// The one way a finished run reaches the library: the save, then the steps its kind's policy names.
    @discardableResult
    func land(_ landing: RunLanding) -> Task<LibraryEntry, any Error> {
        let policy = landing.policy
        let navigation = loadEntryGeneration
        let sidecars = policy.export == .batchPresets ? writeBatchSidecars(landing) : nil
        let saving = saveLanding(landing, navigation: navigation)
        landingSteps = Task { [weak self] in
            let entry = try? await saving.value
            guard let self else { return }
            // Exports read nothing the AI writes, so they don't wait for the card.
            var exports: Task<Void, Never>?
            if policy.export == .rules {
                exports = runAutoExports(
                    transcript: landing.transcript, audioSource: landing.audioSource,
                    source: landing.source, entry: entry, title: landing.title
                )
            }
            if let entry { await finishLanding(entry, landing, navigation: navigation) }
            await exports?.value
            await sidecars?.value
        }
        return saving
    }

    /// Waits for every step of the last landing, exports and delivery included.
    func awaitLandingSteps() async {
        await landingSteps?.value
    }

    private func saveLanding(_ landing: RunLanding, navigation: Int) -> Task<LibraryEntry, any Error> {
        if let entryID = landing.rerunEntryID { return replaceEntry(entryID, with: landing) }
        let beforeSave = beforeLandingSave
        let saving = Task { [weak self, library] in
            do {
                try await beforeSave?()
                let entry = try await library.add(
                    transcript: landing.transcript,
                    audioSource: landing.audioSource,
                    category: landing.category,
                    title: landing.title,
                    titleSource: landing.titleSource,
                    sourceDigest: landing.sourceDigest,
                    source: landing.source,
                    consumesAudio: landing.consumesAudio,
                    takeMarkers: landing.takeMarkers
                )
                self?.place(entry, landing, navigation: navigation)
                return entry
            } catch {
                self?.reportLandingFailure(landing, error)
                throw error
            }
        }
        if landing.policy.selection == .batchCopy { batchLibraryAdds.append(saving) }
        return saving
    }

    /// Favorites, notes, the speaker map and the card metadata all name segments and labels the re-run replaced; a take's markers pick favorites anew.
    private func replaceEntry(_ entryID: LibraryEntry.ID, with landing: RunLanding) -> Task<LibraryEntry, any Error> {
        aiJobs.cancelAll(for: entryID)
        let transcript = landing.transcript
        return Task { [weak self, library] in
            do {
                try await library.updateTranscript(transcript, for: entryID)
                try await library.setTranscriptionDetails(
                    modelName: transcript.modelName, language: transcript.language, for: entryID
                )
                try await library.replaceFavoritesWithTakeMarkers(in: transcript.segments, for: entryID)
                for segmentID in landing.clearingNotes.keys.compactMap(Int.init) {
                    try await library.setSegmentNote(nil, segmentID: segmentID, for: entryID)
                }
                try await library.mutateSpeakerAssignments(for: entryID) { $0 = [:] }
                var entry = try await library.setCardMetadata(aiTitle: nil, shortSummary: nil, for: entryID)
                // A take saved untranscribed loses its note now that it has words; a title the user typed is theirs.
                if entry.manifest.titleSource == nil, let stored = entry.manifest.title,
                   let transcribed = Self.transcribedTitle(from: stored) {
                    entry = try await library.replaceStoredTitle(transcribed, for: entryID)
                }
                self?.place(entry, landing, navigation: 0)
                return entry
            } catch {
                self?.reportLandingFailure(landing, error)
                throw error
            }
        }
    }

    /// Where each file's sidecars landed, which is not always `<stem>.<ext>`.
    private func writeBatchSidecars(_ landing: RunLanding) -> Task<Void, Never>? {
        guard let jobID = landing.batchJobID, let source = landing.audioSource,
              let sidecars = writeSidecars(
                  landing.transcript, presets: batchExportPresets, source: SidecarSource(besideFile: source)
              )
        else { return nil }
        return Task { [weak self] in
            let written = await sidecars.value.compactMap(\.written)
            self?.batchSidecars[jobID] = written
        }
    }

    private func place(_ entry: LibraryEntry, _ landing: RunLanding, navigation: Int) {
        if landing.policy.selection == .keep {
            let interval = Self.landingSignposter.beginInterval("install")
            refreshLibrary()
            if selectedEntryID == entry.id {
                installStoredTranscript(landing.transcript)
                adoptLoadedMediaDuration()
            }
            Self.landingSignposter.endInterval("install", interval)
            return
        }
        let interval = Self.landingSignposter.beginInterval("entry")
        defer { Self.landingSignposter.endInterval("entry", interval) }
        switch landing.policy.selection {
        case .none:
            landLibraryEntry(entry)
        case .unlessNavigated:
            landLibraryEntry(entry)
            // library.add copies media for seconds; a user who navigated meanwhile keeps their selection.
            if loadEntryGeneration == navigation, selectedEntryID == nil { selectLanded(entry.id) }
        case .batchCopy:
            if let jobID = landing.batchJobID { landBatchJobEntry(entry.id, jobID: jobID) }
        case .keep:
            break
        }
    }

    private func reportLandingFailure(_ landing: RunLanding, _ error: any Error) {
        let message: LogMessage = landing.rerunEntryID != nil
            ? "re-transcription could not be saved" : "transcript could not be saved to the library"
        ParolaLog.error(.library, message, [.error: .error(error)])
        nonFatalWarning = Self.landingFailureMessage(landing, reason: error.localizedDescription)
    }

    nonisolated static func landingFailureMessage(
        _ landing: RunLanding, reason: String, bundle: Bundle = .main
    ) -> String {
        switch landing.kind {
        case .rerun, .retriedTake:
            return String(localized: "The transcript ran again, but Parola couldn't save the result. \(reason)", bundle: bundle)
        case .batchJob, .backgroundArrival, .backgroundTake, .backgroundRun:
            // A take goes by its title, its file being a working copy with a made-up name; a link goes by its video's.
            let name = (landing.kind == .backgroundTake ? landing.title : landing.title ?? landing.audioSource?.lastPathComponent) ?? ""
            return String(
                localized: "\(name) was transcribed, but Parola couldn't save it to your library. \(reason)", bundle: bundle
            )
        default:
            return String(
                localized: "The transcript is still open, but Parola couldn't save it to your library. \(reason)",
                bundle: bundle
            )
        }
    }

    private func finishLanding(_ entry: LibraryEntry, _ landing: RunLanding, navigation: Int) async {
        let policy = landing.policy
        if policy.sound { playCompletionSound() }
        if policy.announces {
            arrivalNotice = ArrivalNotice(landed: entry, origin: ArrivalNotice.Origin(landing.kind))
        }
        let card = policy.card ? enqueueCardMetadata(for: entry.id, transcript: landing.transcript) : nil
        switch policy.summary {
        case .never:
            break
        case .whenSelected:
            if loadEntryGeneration == navigation, selectedEntryID == entry.id {
                applyAutostartSummary(to: entry.id, transcript: landing.transcript)
            }
        case .always:
            applyAutostartSummary(to: entry.id, transcript: landing.transcript)
        }
        // Delivery sends the AI title, so only a send waits for the card.
        guard policy.autoSend, hasAutoSendDestination else { return }
        await card?.value
        await autoSendEntry(entry.id)
    }
}
