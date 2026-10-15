import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Entry window viewer")
struct EntryWindowViewerTests {

    @Test("an edit that keeps the segment count still changes the flowing key")
    func aTextEditChangesTheFlowingKey() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerkey")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let before = session.contentSignature

        var edited = try #require(session.transcript)
        edited.segments[0].text = "alpha edited"
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id, reindex: false)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value

        #expect(session.transcript?.segments.count == 2)
        #expect(session.transcript?.segments.first?.text == "alpha edited")
        #expect(session.contentSignature != before)
    }

    @Test("the window's title follows a rename, a late AI title and the AI-title setting")
    func windowFollowsTheTitleTheRowsShow() async throws {
        let model = EntryWindowTestSupport.makeModel("viewertitle")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let store = EntryWindowTestSupport.store(model)
        let original = session.title

        _ = try await store.setCardMetadata(aiTitle: "Weekly planning", shortSummary: nil, for: entry.id)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reloadIfEntryChanged()
        #expect(session.title == "Weekly planning")

        model.showAITitles = false
        session.reloadIfEntryChanged()
        #expect(session.title == original)

        model.showAITitles = true
        session.reloadIfEntryChanged()
        #expect(session.title == "Weekly planning")

        try await store.renameEntry(entry.id, to: "Kickoff call")
        await EntryWindowTestSupport.syncLibrary(model)
        session.reloadIfEntryChanged()
        #expect(session.title == LibraryEntryDisplay.listTitle(
            for: try #require(model.libraryEntry(id: entry.id)), showsAITitle: true
        ))
        model.showAITitles = false
        session.reloadIfEntryChanged()
        #expect(session.title == "Kickoff call")
    }

    @Test("the window's text, speakers, words and flowing key are taken at load and follow a reload")
    func derivationsFollowTheLoad() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerderived")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha beta", "gamma"], speakers: ["Ada", "Bo"], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        #expect(session.transcript?.segments.map(\.text) == ["alpha beta", "gamma"])
        #expect(session.speakers == ["Ada", "Bo"])
        #expect(session.wordCount == 3)
        let before = session.contentSignature
        #expect(before == ContinuousChunks.contentSignature(
            segments: session.transcript?.segments ?? [], useSpeakerColor: true, favoritesOnly: false,
            favorites: [], translations: [:], speakerColorIndices: [:]
        ))

        let edited = EntryWindowTestSupport.transcript(texts: ["alpha", "gamma delta epsilon"], speakers: ["Ada", "Ada"])
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id, reindex: false)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value

        #expect(session.transcript?.segments.map(\.text) == ["alpha", "gamma delta epsilon"])
        #expect(session.speakers == ["Ada"])
        #expect(session.wordCount == 4)
        #expect(session.contentSignature != before)
    }

    @Test("Copy Transcript copies paragraphs with speaker names, as the main window does")
    func copyMatchesTheMainWindow() async throws {
        let model = EntryWindowTestSupport.makeModel("viewercopy")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha beta", "gamma"], speakers: ["Ada", "Bo"], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let viewer = NSPasteboard(name: NSPasteboard.Name("viewer-copy-\(UUID())"))
        let main = NSPasteboard(name: NSPasteboard.Name("main-copy-\(UUID())"))
        defer {
            viewer.releaseGlobally()
            main.releaseGlobally()
        }

        await session.copyTranscript(to: viewer)
        await model.copyTranscriptAsPlainText(try #require(session.transcript), to: main)

        let copied = try #require(viewer.string(forType: .string))
        #expect(copied == main.string(forType: .string))
        #expect(copied.contains("Ada"))
        #expect(copied.contains("Bo"))
    }

    @Test("the word count is the library's when the manifest carries one")
    func wordCountComesFromTheManifest() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerwords")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha beta"], speakers: [nil], audio: nil
        )
        let manifestURL = entry.bundleURL.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.wordCount = 42
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
        await EntryWindowTestSupport.syncLibrary(model)

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.wordCount == 42)
        #expect(session.transcript?.wordCount == 2)
    }

    @Test("a library bump for another entry does not re-read this one")
    func reloadOnlyFollowsThisEntry() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerreload")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let loads = session.loadGeneration

        session.reloadIfEntryChanged()
        #expect(session.loadGeneration == loads, "nothing about this entry changed, so nothing is re-read")

        var edited = try #require(session.transcript)
        edited.segments[0].text = "alpha edited"
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id, reindex: false)
        await EntryWindowTestSupport.syncLibrary(model)

        session.reloadIfEntryChanged()
        await session.loadTask?.value
        #expect(session.loadGeneration == loads + 1)
        #expect(session.transcript?.segments.first?.text == "alpha edited")
    }

    @Test("the window reads favorites and the translation from the document")
    func favoritesAndTranslationComeFromTheDocument() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerdoc")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let store = EntryWindowTestSupport.store(model)
        try await store.setFavoriteSegments([1], for: entry.id)
        try await store.setTranslation(
            TranscriptTranslation(
                targetLanguage: "it", segments: [0: "alfa"], createdAt: Date(), provider: "test"
            ),
            for: entry.id
        )

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.favorites == [1])
        #expect(session.translations == [0: "alfa"])
        #expect(session.transcript?.segments.map(\.text) == ["alpha", "beta"])
    }

    @Test("a speaker assigned to a person wears that person's colour")
    func speakerColoursFollowThePerson() async throws {
        let model = EntryWindowTestSupport.makeModel("viewercolours")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: ["Ada", "SPEAKER_01"], audio: nil
        )
        await model.addPerson(named: "Ada")
        let ada = try #require(model.person(named: "Ada"))
        try await EntryWindowTestSupport.store(model).setSpeakerAssignments(["Ada": ada.id], for: entry.id)
        await model.refreshLibraryAndWait()

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.speakerColorIndices == ["Ada": ada.colorIndex])
        #expect(session.speakers == ["Ada", "SPEAKER_01"])
    }

    @Test("the colours belong to the window's entry, not the one the main pane holds")
    func speakerColoursKeyOnTheWindowsEntry() async throws {
        let model = EntryWindowTestSupport.makeModel("viewercolourskey")
        let shown = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: ["Ada"], audio: nil
        )
        let other = try await EntryWindowTestSupport.seed(
            model, texts: ["beta"], speakers: ["Grace"], audio: nil
        )
        await model.addPerson(named: "Grace")
        let grace = try #require(model.person(named: "Grace"))
        try await EntryWindowTestSupport.store(model).setSpeakerAssignments(["Grace": grace.id], for: other.id)
        await model.refreshLibraryAndWait()
        model.loadEntry(other.id)
        await waitUntil(timeoutMs: 3000) { model.selectedEntryID == other.id }

        let session = await EntryWindowTestSupport.openSession(model, shown)

        #expect(session.speakerColorIndices.isEmpty)
        #expect(model.speakerColorIndices == ["Grace": grace.colorIndex])
    }

    @Test("a search match is painted, the rest of the line is not")
    func matchesArePainted() {
        let highlighted = TranscriptSearchHighlight.attributed(
            "alpha beta",
            matches: [TranscriptMatch(segmentID: 0, range: 6..<10)],
            currentMatchID: nil
        )

        let runs = Array(highlighted.runs)
        #expect(runs.count == 2)
        #expect(runs.first?.backgroundColor == nil)
        #expect(runs.last?.backgroundColor != nil)
        #expect(String(highlighted[runs[1].range].characters) == "beta")
    }

    @Test("the match being stepped through is painted differently from the rest")
    func currentMatchStandsOut() {
        let first = TranscriptMatch(segmentID: 0, range: 0..<5)
        let second = TranscriptMatch(segmentID: 0, range: 6..<11)
        let highlighted = TranscriptSearchHighlight.attributed(
            "alpha alpha",
            matches: [first, second],
            currentMatchID: second.id
        )

        let runs = Array(highlighted.runs)
        #expect(runs.count == 3)
        #expect(runs[0].backgroundColor != runs[2].backgroundColor)
    }

    @Test("a match is painted the same way whether the segment carries stray whitespace or not")
    func paintingIgnoresSurroundingWhitespace() {
        let match = TranscriptMatch(segmentID: 0, range: 7..<11)
        let highlighted = TranscriptSearchHighlight.attributed(
            " alpha beta ",
            matches: [match],
            currentMatchID: match.id
        )

        #expect(String(highlighted.characters) == "alpha beta")
        let runs = Array(highlighted.runs)
        #expect(runs.count == 2)
        #expect(String(highlighted[runs[1].range].characters) == "beta")
        #expect(runs[1].backgroundColor != nil)
    }

    @Test("a match inside a flowing-text chunk is painted where the segment sits")
    func flowingChunkMatchesArePainted() {
        var chunk = AttributedString("alpha beta gamma")
        let match = TranscriptMatch(segmentID: 1, range: 1..<5)

        TranscriptSearchHighlight.paint(
            in: &chunk,
            runOffsets: 5..<10,
            rawText: " beta",
            matches: [match],
            currentMatchID: nil
        )

        let painted = Array(chunk.runs).filter { $0.backgroundColor != nil }
        #expect(painted.count == 1)
        #expect(String(chunk[painted[0].range].characters) == "beta")
    }

    @Test("an entry with no audio shows the transcript and no transport")
    func noAudioMeansNoTransport() async throws {
        let model = EntryWindowTestSupport.makeModel("viewernoaudio")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.player == nil)
        #expect(session.transcript?.segments.count == 1)
        #expect(session.loadFailed == false)
    }

    @Test("the window is titled after the entry")
    func windowCarriesTheEntryTitle() async throws {
        let model = EntryWindowTestSupport.makeModel("viewertitle")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        try await EntryWindowTestSupport.store(model).renameEntry(entry.id, to: "Kickoff call")
        await model.refreshLibraryAndWait()

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.title == "Kickoff call")
    }

    @Test("the viewer leads to the main window to edit: its hint, its Info panel and the Transcript menu")
    func viewerOpensTheEntryInTheMainWindow() async throws {
        let model = EntryWindowTestSupport.makeModel("viewer-edit")
        let entry = try await EntryWindowTestSupport.seed(model, texts: ["alpha"], speakers: [nil], audio: nil)
        var activations = 0
        model.openInMainWindow(entry.id) { activations += 1 }
        let opened = await waitUntil { model.selectedEntryID == entry.id && model.transcript?.segments.first?.text == "alpha" }
        #expect(opened)
        #expect(activations == 1)

        func source(_ name: String) throws -> String {
            let path = #filePath.replacingOccurrences(of: "ParolaAppTests/EntryWindowViewerTests.swift", with: "ParolaApp/\(name).swift")
            return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let window = try source("Windows/EntryWindowView")
        #expect(window.contains(#"Button("Open in Main Window") { model.openInMainWindow(entryID) }"#))
        let info = try source("Windows/EntryViewerInfo")
        #expect(info.contains(#"Button("Open in Main Window") { model.openInMainWindow(session.entryID) }"#))
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Open in Main Window") { model.openKeyViewerInMainWindow() } .disabled(!model.keyWindowIsViewer)"#))
    }

    @Test("Open in Main Window shows the transcript again when a list page covers it")
    func openInMainWindowBringsTheTranscriptBackOverAListPage() async throws {
        let model = EntryWindowTestSupport.makeModel("viewer-list-covers-transcript")
        let entry = try await EntryWindowTestSupport.seed(model, texts: ["alpha"], speakers: [nil], audio: nil)
        model.openInMainWindow(entry.id) {}
        let opened = await waitUntil { model.selectedEntryID == entry.id && model.transcript != nil }
        #expect(opened)

        model.route = .queue
        model.openInMainWindow(entry.id) {}

        let backOnScreen = await waitUntil { model.route == .transcript }
        #expect(backOnScreen)
    }

    @Test("the viewer's Segments layout keeps the main window's reading width")
    func viewerSegmentsKeepTheReadingWidth() async throws {
        let model = EntryWindowTestSupport.makeModel("viewer-width")
        model.transcriptDisplayMode = .segments
        let long = String(repeating: "word ", count: 300)
        let entry = try await EntryWindowTestSupport.seed(model, texts: [long], speakers: [nil], audio: nil)
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let hosted = HostedWindow(EntryViewerSegments(session: session, onEditAttempt: {}).environment(model), width: 1400, height: 600)
        defer { hosted.close() }
        let texts = HostedAccessibility.elements(in: hosted.host).filter { element in
            element.words.contains { $0.hasPrefix("word word") }
        }
        let widest = texts.map(\.frame.width).max() ?? 0
        #expect(!texts.isEmpty)
        #expect(widest <= DS.Size.readingWidth, "the text runs \(widest) pt wide")
    }

    @Test("the viewer shows the language as a pill")
    func windowsShowTheLanguage() throws {
        func source(_ name: String) throws -> String {
            let path = #filePath.replacingOccurrences(of: "ParolaAppTests/EntryWindowViewerTests.swift", with: "ParolaApp/\(name).swift")
            return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let viewerHeader = try source("Windows/EntryViewerHeader")
        #expect(viewerHeader.contains("LanguagePill(language: session.transcript?.language)"))
        #expect(!viewerHeader.contains("Text(verbatim: language)"))
    }

    @Test("the viewer keeps its own pop-up for the speed")
    func viewerKeepsItsSpeedPopUp() async throws {
        let model = EntryWindowTestSupport.makeModel("viewer-speed")
        let entry = try await EntryWindowTestSupport.seed(model, texts: ["alpha"], speakers: [nil], audio: nil)
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let hosted = HostedWindow(EntryViewerPlaybackBar(session: session).environment(model), width: 600, height: 120)
        defer { hosted.close() }
        let found = HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix("Picker.Rate") == true }
        let speed = try #require(found)
        #expect(speed.role == NSAccessibility.Role.popUpButton.rawValue, "the speed reads as \(speed.role ?? "nothing")")
    }

    @Test("the viewer cuts a long title at its end and reads it whole on hover")
    func longTitlesCutAtTheEnd() throws {
        func source(_ name: String) throws -> String {
            let path = #filePath.replacingOccurrences(of: "ParolaAppTests/EntryWindowViewerTests.swift", with: "ParolaApp/\(name).swift")
            return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let viewer = try source("Windows/EntryViewerHeader")
        #expect(viewer.contains("Text(verbatim: session.title) .font(DS.Font.heading) .lineLimit(1) .truncationMode(.tail) .help(Text(verbatim: session.title))"))
    }
}
