import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Library entry display titles")
struct LibraryEntryDisplayTests {
    private let date = Date(timeIntervalSince1970: 1_753_912_800)

    @Test("machine-generated names fall back to a dated recording title", arguments: [
        "parola-recording-6E1B2020-2CB5-4359-A6B2-CBE5B9C25199",
        "parola-system-6e1b2020-2cb5-4359-a6b2-cbe5b9c25199",
        "6E1B2020-2CB5-4359-A6B2-CBE5B9C25199",
        "6e1b2020-2cb5-4359-a6b2-cbe5b9c25199.wav",
        " parola-recording-6E1B2020-2CB5-4359-A6B2-CBE5B9C25199 ",
    ])
    func machineNames(raw: String) {
        #expect(LibraryEntryDisplay.isMachineName(raw))
        #expect(LibraryEntryDisplay.title(raw: raw, createdAt: date) != raw)
    }

    @Test("human titles pass through unchanged", arguments: [
        "Weekly sync",
        "New Recording 129",
        "fixture",
        "Untitled",
        "parola-recording-notes",
        "6E1B2020",
    ])
    func humanTitles(raw: String) {
        #expect(!LibraryEntryDisplay.isMachineName(raw))
        #expect(LibraryEntryDisplay.title(raw: raw, createdAt: date) == raw)
    }

    @Test("a working file's name never becomes the entry's title", arguments: [
        "audio",
        "audio.m4a",
        "Audio.wav",
        " audio ",
        "recording.wav",
        "output.mp3",
    ])
    func genericNames(raw: String) {
        #expect(LibraryEntryDisplay.isPlaceholderName(raw))
        #expect(LibraryEntryDisplay.title(raw: raw, createdAt: date).contains(AppFormat.dateAndTime(date)))
    }

    @Test("a name that only contains a generic word is left alone", arguments: [
        "Audio notes",
        "audiobook",
        "Recording session 3",
        "Output of the meeting",
    ])
    func namesAroundGenericWords(raw: String) {
        #expect(!LibraryEntryDisplay.isPlaceholderName(raw))
        #expect(LibraryEntryDisplay.title(raw: raw, createdAt: date) == raw)
    }

    @Test("an entry saved from a working file reads as a dated recording")
    func entryFromWorkingFile() {
        let entry = LibraryEntry(
            id: "e",
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola"),
            manifest: ParolaDocument.Manifest(
                createdAt: date,
                originalAudioName: "audio.m4a",
                modelName: "stub",
                language: "en"
            )
        )
        #expect(entry.title == "audio")
        #expect(LibraryEntryDisplay.title(for: entry) != "audio")
    }

    @Test("a title the user typed survives even when it reads as generic")
    func userTitleSurvives() {
        let entry = LibraryEntry(
            id: "e",
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola"),
            manifest: ParolaDocument.Manifest(
                createdAt: date,
                originalAudioName: "audio.m4a",
                title: "Audio",
                modelName: "stub",
                language: "en"
            )
        )
        #expect(LibraryEntryDisplay.title(for: entry) == "Audio")
    }

    @Test("fallback title carries the creation date")
    func fallbackCarriesDate() {
        let title = LibraryEntryDisplay.title(raw: "6E1B2020-2CB5-4359-A6B2-CBE5B9C25199", createdAt: date)
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        #expect(title.contains(stamp))
    }

    private func display(
        lastOpenedAt: Date? = nil,
        labels: [String] = [],
        pinned: Bool = false,
        modelName: String = "stub"
    ) -> LibraryRowDisplay {
        let manifest = ParolaDocument.Manifest(
            createdAt: date,
            originalAudioName: "Weekly sync.m4a",
            modelName: modelName,
            language: "en",
            lastOpenedAt: lastOpenedAt,
            labels: labels,
            pinned: pinned
        )
        let entry = LibraryEntry(
            id: "e",
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola"),
            manifest: manifest
        )
        return LibraryRowDisplay(entry: entry)
    }

    @Test("row displays are reused until the library or the excerpts move")
    func displayCacheHoldsUntilItsVersionsChange() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()

        cache.invalidate(libraryVersion: 1, excerptsVersion: 7)
        _ = cache.display(for: entry)
        #expect(cache.displays.count == 1)

        cache.invalidate(libraryVersion: 1, excerptsVersion: 7)
        #expect(cache.displays.count == 1)

        cache.invalidate(libraryVersion: 2, excerptsVersion: 7)
        #expect(cache.displays.isEmpty)

        _ = cache.display(for: entry)
        cache.invalidate(libraryVersion: 2, excerptsVersion: 8)
        #expect(cache.displays.isEmpty)
    }

    /// The index fills in after the rows are already on screen, and a cached row would keep the blank.
    @Test("an entry the index has just reached drops its cached row")
    func displayCacheFollowsTheIndex() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()

        cache.invalidate(libraryVersion: 1, excerptsVersion: 1)
        #expect(cache.display(for: entry, excerpt: nil).excerpt == nil)

        cache.invalidate(libraryVersion: 1, excerptsVersion: 2)
        #expect(cache.displays.isEmpty)
        #expect(cache.display(for: entry, excerpt: "Prime parole.").excerpt == "Prime parole.")
    }

    @Test("a cached display is handed back rather than formatted again")
    func displayCacheReturnsTheSameRow() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()
        cache.invalidate(libraryVersion: 1, excerptsVersion: 1)

        let first = cache.display(for: entry, excerpt: "Prime parole.")
        let second = cache.display(for: entry, excerpt: "Prime parole.")

        #expect(first.id == second.id)
        #expect(first.title == second.title)
        #expect(cache.displays.count == 1)
    }

    @Test("the row caption names the model the entry was transcribed with")
    func rowCarriesTheModelName() {
        #expect(display(modelName: "openai_whisper-large-v3_turbo").modelLabel == "Whisper Large v3 Turbo")
        #expect(display(modelName: "stub").modelLabel == "stub")
        #expect(display(modelName: "  ").modelLabel == nil)
    }

    @Test("a subtitle import names no model")
    func importedSubtitlesHaveNoModel() {
        #expect(display(modelName: "imported-srt").modelLabel == nil)
        #expect(display(modelName: "imported-vtt").modelLabel == nil)
    }

    @Test("a video's own captions read as captions, not as an internal id")
    func youtubeCaptionsReadPlainly() {
        #expect(display(modelName: "youtube-subs").modelLabel == "YouTube subtitles")
        #expect(display(modelName: "youtube-auto-subs").modelLabel == "YouTube auto subtitles")
    }

    @Test("two runs of the same recording differ by their model caption")
    func sameRecordingDifferentModels() {
        let turbo = display(modelName: "openai_whisper-large-v3_turbo")
        let speech = display(modelName: "apple-speech-analyzer")
        #expect(turbo.title == speech.title)
        #expect(turbo.shortDate == speech.shortDate)
        #expect(turbo.modelLabel != speech.modelLabel)
    }

    @Test("a named date replaces the slot a bare day would fill")
    func dateLabelNamesTheSlot() {
        let plain = display()
        let stated = date.addingTimeInterval(-86_400)
        let named = LibraryRowDisplay(entry: plain.entry, date: stated, dateLabel: "Deleted 12 Sep")

        #expect(named.shortDate == "Deleted 12 Sep")
        #expect(named.timeOfDay == "Deleted 12 Sep")
        #expect(plain.shortDate != named.shortDate)
    }

    @Test("without a label the stated date is formatted as a day")
    func statedDateFallsBackToTheDay() {
        let plain = display()
        let stated = date.addingTimeInterval(-86_400)
        let dated = LibraryRowDisplay(entry: plain.entry, date: stated)

        #expect(dated.shortDate == AppFormat.dayAndMonth(stated))
    }

    @Test("the row's hover strings are formatted with the entry, not with every cell")
    func rowStringsAreFormattedOnce() {
        let opened = date.addingTimeInterval(3600)
        let row = display(lastOpenedAt: opened, labels: ["work", "urgent"], pinned: true)

        let lines = row.tooltip.split(separator: "\n").map(String.init)
        #expect(lines.first == "Weekly sync")
        #expect(lines.contains("Labels: work, urgent"))
        #expect(lines.last == "Pinned")
    }
}
