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
    }

    let kind: Kind
    let transcript: Transcript
    var audioSource: URL?
    var source: EntrySource = .file
    var category: EntryCategory = .transcription
    var title: String?
    var titleSource: TitleSource?
    var sourceDigest: String?
    var consumesAudio = false

    var policy: LandingPolicy { kind.policy }
}

/// What a landing does once the run is saved. One row per kind of run, and nothing else decides.
struct LandingPolicy: Equatable, Sendable {
    enum Selection: Equatable, Sendable {
        case none
        /// The saved entry takes the selection, unless the user opened something else while it saved.
        case unlessNavigated
    }

    enum Summary: Equatable, Sendable {
        case never
        /// The autostart rule, for an entry that took the selection.
        case whenSelected
    }

    enum Export: Equatable, Sendable {
        case none
        /// The auto-export rules: beside a file, or in the chosen folder for takes and links.
        case rules
    }

    var selection: Selection
    var sound: Bool
    var card: Bool
    var summary: Summary
    var export: Export
    var autoSend: Bool
    /// The file goes into Open Recent when its run starts.
    var recents: Bool
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
        }
        return saving
    }

    /// Waits for every step of the last landing, exports and delivery included.
    func awaitLandingSteps() async {
        await landingSteps?.value
    }

    /// The category the take in flight was started under; reading it hands the next take the default.
    func takeRecordingCategory() -> EntryCategory {
        defer { pendingRecordingCategory = .transcription }
        return pendingRecordingCategory
    }

    private func saveLanding(_ landing: RunLanding, navigation: Int) -> Task<LibraryEntry, any Error> {
        Task { [weak self, library] in
            do {
                let entry = try await library.add(
                    transcript: landing.transcript,
                    audioSource: landing.audioSource,
                    category: landing.category,
                    title: landing.title,
                    titleSource: landing.titleSource,
                    sourceDigest: landing.sourceDigest,
                    source: landing.source,
                    consumesAudio: landing.consumesAudio
                )
                self?.place(entry, landing, navigation: navigation)
                return entry
            } catch {
                self?.reportLandingFailure(error)
                throw error
            }
        }
    }

    private func place(_ entry: LibraryEntry, _ landing: RunLanding, navigation: Int) {
        let interval = Self.landingSignposter.beginInterval("entry")
        defer { Self.landingSignposter.endInterval("entry", interval) }
        landLibraryEntry(entry)
        switch landing.policy.selection {
        case .none:
            break
        case .unlessNavigated:
            // library.add copies media for seconds; a user who navigated meanwhile keeps their selection.
            if loadEntryGeneration == navigation, selectedEntryID == nil { selectLanded(entry.id) }
        }
    }

    private func reportLandingFailure(_ error: any Error) {
        ParolaLog.error(.library, "transcript could not be saved to the library", [.error: .error(error)])
        nonFatalWarning = "The transcript is still open, but Parola couldn't save it to your library. \(error.localizedDescription)"
    }

    private func finishLanding(_ entry: LibraryEntry, _ landing: RunLanding, navigation: Int) async {
        let policy = landing.policy
        if policy.sound { playCompletionSound() }
        let card = policy.card ? enqueueCardMetadata(for: entry.id, transcript: landing.transcript) : nil
        switch policy.summary {
        case .never:
            break
        case .whenSelected:
            if loadEntryGeneration == navigation, selectedEntryID == entry.id {
                applyAutostartSummary(to: entry.id, transcript: landing.transcript)
            }
        }
        // Delivery sends the AI title, so only a send waits for the card.
        guard policy.autoSend, hasAutoSendDestination else { return }
        await card?.value
        await autoSendEntry(entry.id)
    }
}
