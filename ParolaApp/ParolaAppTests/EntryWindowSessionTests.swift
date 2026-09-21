import Foundation
import Testing
import AVFoundation
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Seeds library entries a window can open, with whatever texts, audio and speakers a test needs.
@MainActor
enum EntryWindowTestSupport {
    static func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    static func transcript(texts: [String], speakers: [String?]) -> Transcript {
        Transcript(
            segments: texts.enumerated().map { index, text in
                TranscriptSegment(
                    id: index,
                    start: Double(index),
                    end: Double(index) + 0.9,
                    text: text,
                    speaker: index < speakers.count ? speakers[index] : nil
                )
            },
            language: "en",
            modelName: "stub"
        )
    }

    static func store(_ model: AppModel) -> LibraryStore {
        // A no-Spotlight store on the model's library dir: the real indexer can hang in the test host.
        LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
    }

    static func seed(
        _ model: AppModel,
        texts: [String],
        speakers: [String?],
        audio: URL?
    ) async throws -> LibraryEntry {
        let entry = try await store(model).add(
            transcript: transcript(texts: texts, speakers: speakers),
            audioSource: audio,
            category: .transcription
        )
        await model.refreshLibraryAndWait()
        return entry
    }

    static func silentAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("entry-window-\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    static func openSession(_ model: AppModel, _ entry: LibraryEntry) async -> EntryWindowSession {
        let session = model.entryWindowSession(for: entry.id)
        await session.loadTask?.value
        return session
    }
}

@MainActor
@Suite("Entry window sessions")
struct EntryWindowSessionTests {

    @Test("two windows on two entries keep their own clock and their own search")
    func sessionsAreIndependent() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsindependent")
        let first = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha one", "alpha two"], speakers: [nil, nil], audio: nil
        )
        let second = try await EntryWindowTestSupport.seed(
            model, texts: ["beta one"], speakers: [nil], audio: nil
        )

        let a = await EntryWindowTestSupport.openSession(model, first)
        let b = await EntryWindowTestSupport.openSession(model, second)

        a.scrub(to: 1.5)
        a.searchQuery = "alpha"

        #expect(a.currentTime == 1.5)
        #expect(b.currentTime == 0)
        #expect(a.matches.count == 2)
        #expect(b.matches.isEmpty)
        #expect(a.transcript?.segments.count == 2)
        #expect(b.transcript?.segments.count == 1)
    }

    @Test("the main window's clock does not move a session's")
    func playbackIsIsolated() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsplayback")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)

        model.installPlayer(for: URL(fileURLWithPath: "/tmp/parola-window-test.m4a"))
        model.currentTimeSeconds = 42
        model.updateCurrentSegment(time: 42)

        #expect(session.currentTime == 0)
        #expect(session.currentSegmentID == nil)

        session.scrub(to: 1.5)

        #expect(model.currentTimeSeconds == 42)
        #expect(session.currentSegmentID == 1)
    }

    @Test("a session with audio holds a player of its own")
    func sessionOwnsItsPlayer() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsplayer")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: try EntryWindowTestSupport.silentAudioFile()
        )

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.player != nil)
        #expect(session.player !== model.player)
    }

    @Test("the registry hands back the same session and drops it on close")
    func registryCreatesOnceAndReleases() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsregistry")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )

        let first = model.entryWindowSession(for: entry.id)
        let second = model.entryWindowSession(for: entry.id)

        #expect(first === second)
        #expect(model.openEntryWindowIDs == [entry.id])

        model.releaseEntryWindow(entry.id)

        #expect(model.openEntryWindowIDs.isEmpty)
        #expect(model.entryWindowSession(for: entry.id) !== first)
    }

    @Test("an entry that is gone leaves an empty window instead of crashing")
    func missingEntryLoadsEmpty() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsmissing")

        let session = model.entryWindowSession(for: "not-a-real-entry")
        await session.loadTask?.value

        #expect(session.transcript == nil)
        #expect(session.loadFailed)
        #expect(session.isLoading == false)
        #expect(session.currentSegmentID == nil)
        #expect(session.player == nil)
    }

    @Test("stepping through matches moves the window's own selection")
    func matchNavigationStaysInTheWindow() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsmatches")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "alpine", "almond"], speakers: [nil, nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)

        session.searchQuery = "al"

        #expect(session.matches.count == 3)
        #expect(session.currentSegmentID == 0)

        session.goToNextMatch()
        #expect(session.currentSegmentID == 1)

        session.goToPreviousMatch()
        #expect(session.currentSegmentID == 0)

        session.goToPreviousMatch()
        #expect(session.currentSegmentID == 2)
        #expect(model.currentSegmentID == nil)
    }

    @Test("releasing a session stops its player")
    func releaseStopsPlayback() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsrelease")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: try EntryWindowTestSupport.silentAudioFile()
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let player = try #require(session.player)

        model.releaseEntryWindow(entry.id)

        #expect(session.player == nil)
        #expect(player.timeControlStatus != .playing)
    }

    @Test("a segment click seeks the window's own clock")
    func segmentClickSeeksTheSession() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsseek")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta", "gamma"], speakers: [nil, nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)

        session.seek(toSegment: 2)

        #expect(session.currentTime == 2)
        #expect(session.currentSegmentID == 2)
        #expect(model.currentTimeSeconds == 0)
    }
}
