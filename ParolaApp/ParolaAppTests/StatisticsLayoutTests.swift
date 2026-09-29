import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics tile grid")
struct StatisticsTileGridTests {
    private func pageWidth(window: CGFloat) -> CGFloat {
        window - MainWindowLayout.sidebarMaxWidth - 2 * DS.Spacing.large
    }

    @Test("five tiles sit in one row in the wide window and wrap to three and two in the smallest")
    func columnsFollowTheWidth() {
        #expect(TileGrid.columns(fitting: pageWidth(window: 1180)) == 5)
        #expect(TileGrid.columns(fitting: pageWidth(window: MainWindowLayout.minimumWidth)) == 3)
    }

    @Test("no width leaves a tile alone on its own row")
    func neverALoneTile() {
        for width in stride(from: 300.0, through: 2400.0, by: 4) {
            #expect(!TileGrid.leavesLoneTile(width: width), "\(width)")
        }
    }
}

@Suite("Statistics kind bar")
struct StatisticsKindBarTests {
    @Test("segments are proportional to the counts and the empty kinds draw none")
    func sharesAreProportional() {
        let shares = KindShare.shares(counts: [(.transcription, 3), (.meeting, 1), (.dictation, 0)])
        #expect(shares == [
            KindShare(category: .transcription, share: 0.75),
            KindShare(category: .meeting, share: 0.25),
        ])
        #expect(KindShare.shares(counts: [(.transcription, 0), (.meeting, 0)]).isEmpty)
        #expect(KindShare.shares(counts: [(.dictation, 7)]) == [KindShare(category: .dictation, share: 1)])
    }
}

@Suite("Statistics records")
struct StatisticsRecordsTests {
    private let english = Locale(identifier: "en_US")
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, audio: Double, timing: Double?) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.reference,
            originalAudioName: "\(id).wav",
            modelName: "whisper",
            language: "en",
            durationSeconds: audio
        )
        manifest.transcriptionSeconds = timing
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"), manifest: manifest)
    }

    private func stats(_ entries: [LibraryEntry]) -> LibraryStatistics {
        LibraryStatistics.compute(entries: entries, now: Self.reference, calendar: Calendar(identifier: .gregorian))
    }

    @Test("the records come in a fixed order, each with its entry and its value spelled out")
    func recordsAreBuiltInOrder() {
        let quick = entry("quick", audio: 600, timing: 37.5)
        let long = entry("long", audio: 12_500, timing: 1_205)
        let library = ["quick": quick, "long": long]

        let records = StatisticsRecord.records(from: stats([quick, long]), entry: { library[$0] }, locale: english)

        #expect(records.map(\.kind) == [.longestTranscript, .longestRun, .fastestRun])
        #expect(records.map(\.entry.id) == ["long", "long", "quick"])
        #expect(records.map(\.value) == ["3 hr, 28 min", "20 min, 5 sec", "16×\u{00A0}real time"])
    }

    @Test("a record whose entry has left the library is not shown, and an untimed library has only the longest transcript")
    func missingRecordsAreLeftOut() {
        let quick = entry("quick", audio: 600, timing: 37.5)
        let long = entry("long", audio: 12_500, timing: 1_205)

        let withoutQuick = StatisticsRecord.records(from: stats([quick, long]), entry: { $0 == "long" ? long : nil }, locale: english)
        #expect(withoutQuick.map(\.kind) == [.longestTranscript, .longestRun])

        let untimed = entry("untimed", audio: 300, timing: nil)
        let onlyAudio = StatisticsRecord.records(from: stats([untimed]), entry: { _ in untimed }, locale: english)
        #expect(onlyAudio.map(\.kind) == [.longestTranscript])
        #expect(onlyAudio.first?.value == "5 min")
    }

    @Test("a row names its entry the way the library list does, generated title included")
    func rowTitleFollowsTheList() {
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.reference, originalAudioName: "board.wav", title: "Board call", modelName: "whisper", language: "en"
        )
        manifest.titleSource = .user
        manifest.aiTitle = "Quarterly board call"
        let entry = LibraryEntry(id: "board", bundleURL: URL(fileURLWithPath: "/tmp/board.parola"), manifest: manifest)

        // A title the user typed outranks the generated one, whatever "Show AI Titles" is set to.
        #expect(LibraryEntryDisplay.listTitle(for: entry, showsAITitle: true) == "Board call")
        #expect(LibraryEntryDisplay.listTitle(for: entry, showsAITitle: false) == "Board call")

        manifest.title = nil
        manifest.titleSource = nil
        let untitled = LibraryEntry(id: "board", bundleURL: entry.bundleURL, manifest: manifest)
        #expect(LibraryEntryDisplay.listTitle(for: untitled, showsAITitle: true) == "Quarterly board call")
        #expect(LibraryEntryDisplay.listTitle(for: untitled, showsAITitle: false) == "board")
    }
}
