import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript render breadth", .serialized)
struct TranscriptRenderBreadthTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-render-breadth-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("render-breadth"))
        model.libraryLoaded = true
        return model
    }

    private static func talk(segments count: Int = 40) -> Transcript {
        Transcript(
            segments: (0..<count).map { index in
                let start = Double(index * 4)
                return TranscriptSegment(
                    id: index,
                    start: start,
                    end: start + 3.5,
                    text: "Turn number \(index) about the plan",
                    speaker: index.isMultiple(of: 2) ? "SPEAKER_00" : "SPEAKER_01",
                    words: ["Turn", "number", "\(index)", "about", "the", "plan"].enumerated().map { offset, word in
                        WordTiming(id: "\(index)-\(offset)", word: word, start: start + Double(offset) * 0.5, end: start + Double(offset) * 0.5 + 0.4, probability: 0.95)
                    }
                )
            },
            language: "en",
            modelName: "stub",
            durationSeconds: Double(count * 4)
        )
    }

    private func open(_ transcript: Transcript, in model: AppModel) async throws -> LibraryEntry {
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await store.add(transcript: transcript, audioSource: nil, category: .transcription)
        await model.library.dropCaches()
        await model.refreshLibraryAndWait()
        try await awaitGuarded("opening \(entry.id)") { _ = try await model.openEntry(entry.id) }
        await awaitGuarded("the open's library refresh") { await model.libraryRefreshTask?.value }
        model.phase = .ready
        return entry
    }

    private func probe(_ name: String) -> Int { BodyProbe.counts[name] ?? 0 }

    @Test("a library write that changes nothing the cards show re-runs none of them")
    func libraryWritesLeaveTheCardsAlone() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let entry = try await open(Self.talk(), in: model)
            let hosted = HostedWindow(SegmentsScroll().environment(model), width: 700, height: 900)
            defer { hosted.close() }
            let drawn = await waitUntil { probe("SegmentCard") > 3 }
            #expect(drawn)
            await settle()

            BodyProbe.counts = [:]
            model.patchLibraryEntry(id: entry.id) { $0.lastOpenedAt = Date() }
            model.patchLibraryEntry(id: entry.id) { $0.title = "Renamed" }
            await settle()
            #expect(probe("SegmentCard") == 0, "\(BodyProbe.counts)")
            #expect(probe("SegmentsScroll") == 0, "\(BodyProbe.counts)")
        }
    }

    @Test("a segment boundary re-runs the two cards that change and nothing above them")
    func aBoundaryTouchesTwoCards() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.talk(), in: model)
            let hosted = HostedWindow(SegmentsScroll().environment(model), width: 700, height: 900)
            defer { hosted.close() }
            let drawn = await waitUntil { probe("SegmentCard") > 3 }
            #expect(drawn)
            model.currentSegmentID = 1
            await settle()

            BodyProbe.counts = [:]
            model.currentSegmentID = 2
            await settle()
            let rerun = probe("SegmentCard")
            #expect(rerun >= 1 && rerun <= 2, "\(BodyProbe.counts)")
            #expect(probe("SegmentsScroll") == 0, "\(BodyProbe.counts)")
        }
    }

    @Test("the word being spoken re-runs no card")
    func aWordTouchesNoCard() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.talk(), in: model)
            model.karaokeHighlight = true
            let hosted = HostedWindow(SegmentsScroll().environment(model), width: 700, height: 900)
            defer { hosted.close() }
            let drawn = await waitUntil { probe("SegmentCard") > 3 }
            #expect(drawn)
            model.currentSegmentID = 2
            model.currentWordID = "2-0"
            await settle()

            BodyProbe.counts = [:]
            for word in 1..<6 {
                model.currentWordID = "2-\(word)"
                await settle(for: .milliseconds(40))
            }
            #expect(probe("SegmentCard") == 0, "\(BodyProbe.counts)")
            #expect(probe("SegmentsScroll") == 0, "\(BodyProbe.counts)")
        }
    }

    @Test("the selected entry's favorites, notes and speaker map are stored copies that follow the library and the selection")
    func selectedEntryMirrors() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let entry = try await open(Self.talk(segments: 6), in: model)
            let person = UUID()
            model.patchLibraryEntry(id: entry.id) {
                $0.favoriteSegments = [1, 4]
                $0.segmentNotes = ["2": "check this"]
                $0.speakerAssignments = ["SPEAKER_00": person]
            }
            #expect(model.selectedEntryFavorites == [1, 4])
            #expect(model.isSegmentFavorite(4) && !model.isSegmentFavorite(0))
            #expect(model.favoriteSegmentIDs == [1, 4])
            #expect(model.currentSegmentNote(for: 2) == "check this")
            #expect(model.currentSegmentNote(for: 1) == nil)
            #expect(model.speakerAssignments == ["SPEAKER_00": person])
            #expect(model.selectedEntryHasFavorites)

            model.selectedEntryID = nil
            #expect(model.selectedEntryFavorites.isEmpty && model.selectedEntryNotes.isEmpty && model.speakerAssignments.isEmpty)
            #expect(!model.selectedEntryHasFavorites)
            model.selectedEntryID = entry.id
            #expect(model.selectedEntryFavorites == [1, 4])
        }
    }

    @Test("the people order is built when the directory or the usage counts change, not when it is read")
    func peopleOrderIsStored() async throws {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let people = (0..<25).map { index in
                Person(name: "Person \(String(format: "%02d", (index * 7) % 25))", lastUsedAt: Date(timeIntervalSince1970: Double(index * 100)))
            }
            model.people = people
            let builds = model.peopleOrderBuilds
            for _ in 0..<50 {
                _ = model.peopleByUse
                _ = model.personMenuChoices(limit: 10)
                _ = model.segmentSpeakerChoices(peopleLimit: 10)
            }
            #expect(model.peopleOrderBuilds == builds)

            let newest = people.sorted { $0.lastUsedAt > $1.lastUsedAt }
            #expect(model.peopleByUse == newest)
            let choices = model.personMenuChoices(excluding: [newest[0].name], limit: 10)
            let offered = newest.filter { $0.name != newest[0].name }
            #expect(choices.top == Array(offered.prefix(10)))
            let expectedMore = offered.dropFirst(10).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            #expect(choices.more == expectedMore)

            model.people = people + [Person(name: "Zed")]
            #expect(model.peopleOrderBuilds == builds + 1)
            let hasZed = model.peopleByUse.contains { $0.name == "Zed" }
            #expect(hasZed)
        }
    }
}
