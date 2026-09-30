import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Landing policy", .serialized)
struct LandingPolicyTests {

    private actor Tally {
        var cards = 0
        var summaries = 0
        func card() { cards += 1 }
        func summary() { summaries += 1 }
    }

    @MainActor
    private final class Sounds {
        var plays = 0
    }

    private struct Rig {
        let model: AppModel
        let sounds: Sounds
        let tally: Tally
        let recorder: MockDeliveryRecorder
        let folder: URL
        let source: URL
    }

    private static let text = String(repeating: "Every run lands through one hook. ", count: 4)

    private static func transcript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "stub",
            durationSeconds: 1
        )
    }

    private func makeRig(_ label: String) throws -> Rig {
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("landing-\(label)")
        )
        let sounds = Sounds()
        let tally = Tally()
        let recorder = MockDeliveryRecorder()
        model.completionSoundPlayer = { sounds.plays += 1 }
        model.playSoundWhenFinished = true
        model.cardMetadataOperation = { _ in
            await tally.card()
            return CardMetadata(title: "Titled", summary: "Summed up.")
        }
        model.autostartSummary = true
        model.summariseOperation = { _, _ in
            await tally.summary()
            return Summary(text: "summed up")
        }
        model.sweptFolders = { [] }
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])
        ]
        model.batchExportPresetIDs = [ExportPreset.builtIn(for: .srt)!.id]
        model.setDestinations([.mock(MockDestination(
            name: "Mock vault", autoSend: true, categories: Set(EntryCategory.allCases), recorder: recorder
        ))])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-landing-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("clip.wav")
        try Data("RIFFfakeaudio".utf8).write(to: source)
        return Rig(model: model, sounds: sounds, tally: tally, recorder: recorder, folder: folder, source: source)
    }

    private func exports(in rig: Rig) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: rig.folder.path)).subtracting(["clip.wav"])
    }

    private func landing(_ kind: RunLanding.Kind, in rig: Rig) async throws -> RunLanding {
        switch kind {
        case .batchJob:
            let job = BatchJob(url: rig.source, status: .transcribing)
            rig.model.batchJobs = [job]
            return .batchJob(job, transcript: Self.transcript())
        case .rerun:
            let earlier = try await rig.model.library.add(transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the first run")],
                language: "en",
                modelName: "stub"
            ), audioSource: nil)
            return .rerun(of: earlier.id, transcript: Self.transcript(), clearingNotes: [:])
        case .retriedTake:
            let saved = try await rig.model.library.add(
                transcript: Transcript(segments: [], language: "en", modelName: ""), audioSource: nil
            )
            return RunLanding(kind: .retriedTake, transcript: Self.transcript(), audioSource: rig.source, rerunEntryID: saved.id)
        default:
            return RunLanding(kind: kind, transcript: Self.transcript(), audioSource: rig.source)
        }
    }

    private static func expectedExports(_ export: LandingPolicy.Export) -> Set<String> {
        switch export {
        case .none: []
        case .rules: ["clip.txt"]
        case .batchPresets: ["clip.srt", "clip.txt"]
        }
    }

    @Test("the table names every kind's steps")
    func table() {
        let expected: [RunLanding.Kind: LandingPolicy] = [
            .file: LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: true
            ),
            .link: LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            ),
            .recording: LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            ),
            .salvagedTake: LandingPolicy(
                selection: .none, sound: false, card: false, summary: .never,
                export: .none, autoSend: false, recents: false
            ),
            .subtitles: LandingPolicy(
                selection: .unlessNavigated, sound: false, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: true
            ),
            .captions: LandingPolicy(
                selection: .unlessNavigated, sound: false, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            ),
            .batchJob: LandingPolicy(
                selection: .batchCopy, sound: false, card: true, summary: .never,
                export: .batchPresets, autoSend: false, recents: false
            ),
            .rerun: LandingPolicy(
                selection: .keep, sound: true, card: true, summary: .never,
                export: .none, autoSend: false, recents: false
            ),
            .retriedTake: LandingPolicy(
                selection: .keep, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            ),
            .arrival: LandingPolicy(
                selection: .unlessNavigated, sound: true, card: true, summary: .whenSelected,
                export: .rules, autoSend: true, recents: false
            ),
            .backgroundArrival: LandingPolicy(
                selection: .none, sound: false, card: true, summary: .always,
                export: .rules, autoSend: true, recents: false, announces: true
            ),
            .backgroundTake: LandingPolicy(
                selection: .none, sound: true, card: true, summary: .always,
                export: .rules, autoSend: true, recents: false, announces: true
            ),
        ]
        #expect(Set(expected.keys) == Set(RunLanding.Kind.allCases))
        for kind in RunLanding.Kind.allCases {
            #expect(kind.policy == expected[kind], "\(kind)")
        }
    }

    @Test("a landing runs exactly the steps its kind's policy names", arguments: RunLanding.Kind.allCases)
    func landingRunsItsSteps(kind: RunLanding.Kind) async throws {
        let rig = try makeRig("\(kind)")
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let policy = kind.policy

        let entry = try await rig.model.land(try await landing(kind, in: rig)).value
        await rig.model.awaitLandingSteps()
        await rig.model.awaitCardMetadataQueue()

        let selected = rig.model.selectedEntryID == entry.id
        #expect(selected == (policy.selection == .unlessNavigated))
        #expect(rig.sounds.plays == (policy.sound ? 1 : 0))
        #expect(await rig.tally.cards == (policy.card ? 1 : 0))
        #expect(await rig.recorder.recorded().map(\.entryID) == (policy.autoSend ? [entry.id] : []))
        #expect(try exports(in: rig) == Self.expectedExports(policy.export))
        #expect((rig.model.arrivalNotice?.state == .saved(entry.id)) == policy.announces)
        if policy.summary == .always || (policy.summary == .whenSelected && selected) {
            let summarized = await waitUntil { await rig.tally.summaries == 1 }
            #expect(summarized)
        } else {
            await settle()
            #expect(await rig.tally.summaries == 0)
        }
    }

    @Test("an entry the user navigated away from saves without taking the selection or the summary")
    func navigationKeepsTheSelection() async throws {
        let rig = try makeRig("navigated")
        defer { try? FileManager.default.removeItem(at: rig.folder) }

        let saving = rig.model.land(RunLanding(kind: .file, transcript: Self.transcript(), audioSource: rig.source))
        rig.model.loadEntryGeneration &+= 1
        let entry = try await saving.value
        await rig.model.awaitLandingSteps()

        #expect(rig.model.selectedEntryID == nil)
        #expect(rig.model.libraryEntries.map(\.id) == [entry.id])
        #expect(await rig.recorder.recorded().map(\.entryID) == [entry.id])
        await settle()
        #expect(await rig.tally.summaries == 0)
    }

    @Test("a take lands in the category it carries")
    func takeLandsInItsCategory() async throws {
        let rig = try makeRig("category")
        defer { try? FileManager.default.removeItem(at: rig.folder) }

        let entry = try await rig.model.land(RunLanding(
            kind: .recording, transcript: Self.transcript(), source: .systemAudio, category: .meeting
        )).value

        #expect(entry.category == .meeting)
    }
}

extension LandingPolicyTests {
    @Test("a batch job's landing links the job to its entry and waits for the batch's refresh")
    func batchJobLinksItsEntry() async throws {
        let rig = try makeRig("batch-link")
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let refreshes = rig.model.libraryRefreshes

        let entry = try await rig.model.land(try await landing(.batchJob, in: rig)).value

        #expect(rig.model.batchJobs.first?.entryID == entry.id)
        #expect(rig.model.batchJobs.first?.transcript == nil)
        #expect(rig.model.libraryEntries.isEmpty)
        #expect(rig.model.libraryRefreshes == refreshes)
        #expect(rig.model.batchLibraryAdds.count == 1)
    }
}

extension LandingPolicyTests {
    @Test("a re-run keeps the open entry, shows the new text and clears what named the old segments")
    func rerunKeepsTheOpenEntry() async throws {
        let rig = try makeRig("rerun-open")
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let earlier = try await rig.model.library.add(transcript: Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the first run")],
            language: "en",
            modelName: "stub"
        ), audioSource: nil)
        try await rig.model.library.setFavoriteSegments([0], for: earlier.id)
        try await rig.model.library.setSegmentNote("keep an eye", segmentID: 0, for: earlier.id)
        try await rig.model.openEntry(earlier.id)
        let refreshes = rig.model.libraryRefreshes

        let entry = try await rig.model.land(.rerun(
            of: earlier.id, transcript: Self.transcript(), clearingNotes: ["0": "keep an eye"]
        )).value

        #expect(entry.id == earlier.id)
        #expect(rig.model.selectedEntryID == earlier.id)
        #expect(rig.model.transcript?.segments.first?.text == Self.text)
        #expect(rig.model.libraryRefreshes == refreshes + 1)
        let stored = try await rig.model.library.load(earlier.id)
        #expect(stored.document.transcript.segments.first?.text == Self.text)
        #expect(stored.entry.manifest.favoriteSegments.isEmpty)
        #expect(stored.entry.segmentNotes.isEmpty)
    }
}

extension LandingPolicyTests {
    @Test("a landing that couldn't be saved says so in Italian too")
    func saveFailureMessagesAreTranslated() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let transcript = Self.transcript()
        let background = RunLanding(
            kind: .backgroundArrival, transcript: transcript, audioSource: URL(fileURLWithPath: "/tmp/Memo.m4a")
        )
        let open = RunLanding(kind: .file, transcript: transcript)

        #expect(AppModel.landingFailureMessage(background, reason: "Disco pieno.", bundle: italian)
            == "Memo.m4a è stato trascritto, ma Parola non è riuscita a salvarlo nella libreria. Disco pieno.")
        #expect(AppModel.landingFailureMessage(open, reason: "Disco pieno.", bundle: italian)
            == "La trascrizione è ancora aperta, ma Parola non è riuscita a salvarla nella libreria. Disco pieno.")
        #expect(AppModel.landingFailureMessage(background, reason: "Disk full.")
            == "Memo.m4a was transcribed, but Parola couldn't save it to your library. Disk full.")
        let take = RunLanding(
            kind: .backgroundTake, transcript: transcript, audioSource: URL(fileURLWithPath: "/tmp/parola-mic-1.wav"),
            title: "Recording 30 Sep 2026 at 13:39"
        )
        #expect(AppModel.landingFailureMessage(take, reason: "Disk full.")
            == "Recording 30 Sep 2026 at 13:39 was transcribed, but Parola couldn't save it to your library. Disk full.")
    }
}
