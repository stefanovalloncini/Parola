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

        let entry = try await rig.model.land(RunLanding(
            kind: kind, transcript: Self.transcript(), audioSource: rig.source
        )).value
        await rig.model.awaitLandingSteps()
        await rig.model.awaitCardMetadataQueue()

        let selected = rig.model.selectedEntryID == entry.id
        #expect(selected == (policy.selection == .unlessNavigated))
        #expect(rig.sounds.plays == (policy.sound ? 1 : 0))
        #expect(await rig.tally.cards == (policy.card ? 1 : 0))
        #expect(await rig.recorder.recorded().map(\.entryID) == (policy.autoSend ? [entry.id] : []))
        #expect(try exports(in: rig) == (policy.export == .rules ? ["clip.txt"] : []))
        if policy.summary == .whenSelected, selected {
            #expect(await waitUntil { await rig.tally.summaries == 1 })
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

    @Test("a take lands in the category it was started under, and the next take starts from the default")
    func takeCategoryIsHandedBack() async throws {
        let rig = try makeRig("category")
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.pendingRecordingCategory = .meeting

        let entry = try await rig.model.land(RunLanding(
            kind: .recording, transcript: Self.transcript(), source: .systemAudio,
            category: rig.model.takeRecordingCategory()
        )).value

        #expect(entry.category == .meeting)
        #expect(rig.model.pendingRecordingCategory == .transcription)
    }
}
