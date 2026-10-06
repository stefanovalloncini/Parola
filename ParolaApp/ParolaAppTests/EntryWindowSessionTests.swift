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
            modelName: "stub",
            durationSeconds: Double(texts.count) - 0.1
        )
    }

    /// A box for the ids a bound open action was handed, so an escaping closure can record them.
    @MainActor
    final class OpenedWindows {
        var ids: [LibraryEntry.ID] = []
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
        await syncLibrary(model)
        return entry
    }

    /// The tests write through a second store on the same directory, so the model's store has to be
    /// told its cached listing and documents are stale.
    static func syncLibrary(_ model: AppModel) async {
        await model.library.dropCaches()
        await model.refreshLibraryAndWait()
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
        let matchesReachedTwo = await waitUntil { a.matches.count == 2 }
        #expect(matchesReachedTwo)

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
        #expect(model.currentSegmentID == nil)

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

        model.releaseEntryWindow(first)

        #expect(model.openEntryWindowIDs.isEmpty)
        #expect(model.entryWindowSession(for: entry.id) !== first)
    }

    @Test("a late close report does not take down the window that replaced it")
    func releaseChecksIdentity() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsreplaced")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )

        let first = model.entryWindowSession(for: entry.id)
        model.releaseEntryWindow(first)
        let second = model.entryWindowSession(for: entry.id)

        model.releaseEntryWindow(first)

        #expect(second !== first)
        #expect(model.openEntryWindowIDs == [entry.id])
        #expect(model.entryWindowSession(for: entry.id) === second)
    }

    @Test("a theme change leaves an open window alone")
    func themeChangeKeepsTheSession() async throws {
        let defaults = temporaryDefaults()
        let model = AppModel(
            skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("windowstheme")
        )
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: try EntryWindowTestSupport.silentAudioFile()
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let player = try #require(session.player)
        let revisionBefore = model.themeRevision

        defaults.set(AppAccent.allCases.first { $0 != model.appAccent }?.rawValue, forKey: AppAccent.storageKey)
        model.reloadSettings()

        #expect(model.themeRevision != revisionBefore)
        #expect(model.openEntryWindowIDs == [entry.id])
        #expect(model.entryWindowSession(for: entry.id) === session)
        #expect(session.player === player)
    }

    @Test("nothing opens, and nothing is registered, until a scene can show a window")
    func openNeedsAWindowScene() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsunbound")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )

        #expect(model.openEntryWindow(entry.id) == false)
        #expect(model.openEntryWindowIDs.isEmpty)

        let opened = EntryWindowTestSupport.OpenedWindows()
        model.bindOpenEntryWindow { opened.ids.append($0) }

        #expect(model.openEntryWindow(entry.id))
        #expect(opened.ids == [entry.id])
        #expect(model.openEntryWindowIDs == [entry.id])
    }

    @Test("a library change reloads the window and keeps its place")
    func reloadKeepsThePlace() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsreload")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        session.scrub(to: 1.2)
        session.searchQuery = "beta"
        let sessionMatchesReachedOne = await waitUntil { session.matches.count == 1 }
        #expect(sessionMatchesReachedOne)

        try await EntryWindowTestSupport.store(model).setFavoriteSegments([1], for: entry.id)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value

        #expect(session.favorites == [1])
        #expect(session.currentTime == 1.2)
        #expect(session.searchQuery == "beta")
        #expect(session.matches.count == 1)
        #expect(session.loadFailed == false)
    }

    @Test("a reload rescans the standing query over the new text and keeps the reader's match")
    func reloadKeepsTheReadersMatch() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsrescan")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["beta", "beta two"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        session.searchQuery = "beta"
        let sessionMatchesReachedTwo = await waitUntil { session.matches.count == 2 }
        #expect(sessionMatchesReachedTwo)
        session.goToNextMatch()
        #expect(session.currentMatchIndex == 1)

        let edited = EntryWindowTestSupport.transcript(texts: ["beta", "beta beta", "gamma"], speakers: [nil, nil, nil])
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value
        await session.matchesTask?.value

        #expect(session.matches.map(\.segmentID) == [0, 1, 1])
        #expect(session.matches(in: 1).map(\.range) == [0..<4, 5..<9])
        #expect(session.currentMatchIndex == 1)
    }

    @Test("a new query still jumps to its first match when a reload's scan supersedes its own")
    func newQueryJumpSurvivesAReload() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsresetpending")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha one", "beta", "alpha two", "alpine three"], speakers: [nil, nil, nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        session.searchQuery = "alpha"
        let sessionMatchesReachedTwo = await waitUntil { session.matches.count == 2 }
        #expect(sessionMatchesReachedTwo)
        session.goToNextMatch()
        #expect(session.currentMatchIndex == 1)
        #expect(session.currentSegmentID == 2)

        let gate = ScanGate()
        session.scanMatches = { transcript, query in
            await gate.enter()
            return transcript.findMatches(query)
        }
        session.searchQuery = "alp"
        let gateIsHolding = await waitUntil { await gate.isHolding }
        #expect(gateIsHolding)

        session.reload()
        await session.loadTask?.value
        await session.matchesTask?.value
        await gate.open()

        #expect(session.matches.map(\.segmentID) == [0, 2, 3])
        #expect(session.currentMatchIndex == 0)
        #expect(session.currentSegmentID == 0)
    }

    @Test("reloading an entry that has gone leaves the empty state")
    func reloadOfADeletedEntryEmpties() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsreloadgone")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: try EntryWindowTestSupport.silentAudioFile()
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        #expect(session.player != nil)

        try await EntryWindowTestSupport.store(model).purge(entry.id)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value

        #expect(session.transcript == nil)
        #expect(session.loadFailed)
        #expect(session.player == nil)
        #expect(session.visibleSegments.isEmpty)
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
        let sessionMatchesReachedThree = await waitUntil { session.matches.count == 3 }
        #expect(sessionMatchesReachedThree)

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

        model.releaseEntryWindow(session)

        #expect(session.player == nil)
        #expect(player.timeControlStatus != .playing)
    }

    @Test("the clock never runs past the media")
    func scrubIsClamped() async throws {
        let model = EntryWindowTestSupport.makeModel("windowsclamp")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)

        session.scrub(to: 500)
        #expect(session.currentTime == session.durationSeconds)

        session.skip(by: 500)
        #expect(session.currentTime == session.durationSeconds)

        session.skip(by: -500)
        #expect(session.currentTime == 0)
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

/// Holds the first scan it sees until the test opens it; later scans pass straight through.
private actor ScanGate {
    private var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var isHolding = false

    func enter() async {
        calls += 1
        guard calls == 1, !isOpen else { return }
        isHolding = true
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
