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

    @Test("a link's entry says it came from the web, not from a recording")
    func webVideoTitleNamesItsSource() {
        let title = LibraryEntryDisplay.webVideoTitle(createdAt: date)
        #expect(title.contains(AppFormat.dateAndTime(date)))
        #expect(title != LibraryEntryDisplay.title(raw: "audio.m4a", createdAt: date))
    }

    /// The empty audio name is the subtitles path, which keeps no working file and would otherwise read "Untitled".
    @Test("a stored web-video title is left alone by the placeholder rules",
          arguments: ["audio.m4a", ""])
    func webVideoTitleSurvivesTheDisplayPath(audioName: String) {
        let stored = LibraryEntryDisplay.webVideoTitle(createdAt: date)
        let entry = LibraryEntry(
            id: "e",
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola"),
            manifest: ParolaDocument.Manifest(
                createdAt: date,
                originalAudioName: audioName,
                title: stored,
                modelName: "stub",
                language: "en"
            )
        )
        #expect(LibraryEntryDisplay.title(for: entry) == stored)
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

    @Test("the list resolver orders a real title over the AI title over a generated stamp")
    func listTitleOrder() {
        let base = ParolaDocument.Manifest(
            createdAt: date, originalAudioName: "meeting.wav", modelName: "stub", language: "en"
        )
        let bundle = URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola")

        var userTitled = base
        userTitled.title = "Weekly sync"
        userTitled.titleSource = .user
        userTitled.aiTitle = "Planning and roadmap"
        let userEntry = LibraryEntry(id: "e", bundleURL: bundle, manifest: userTitled)
        #expect(LibraryEntryDisplay.listTitle(for: userEntry, showsAITitle: true) == "Weekly sync")
        #expect(LibraryEntryDisplay.listTitle(for: userEntry, showsAITitle: false) == "Weekly sync")

        var sourceTitled = base
        sourceTitled.title = "Keynote: What's New"
        sourceTitled.titleSource = .source
        sourceTitled.aiTitle = "Product announcements"
        let sourceEntry = LibraryEntry(id: "e", bundleURL: bundle, manifest: sourceTitled)
        #expect(LibraryEntryDisplay.listTitle(for: sourceEntry, showsAITitle: true) == "Keynote: What's New")

        // A generated stamp with no recorded source loses to the AI title, same as no stored title at all.
        var stampedNoSource = base
        stampedNoSource.title = "Recording 18 May 2026 at 09:00"
        stampedNoSource.aiTitle = "Planning and roadmap"
        let stampedEntry = LibraryEntry(id: "e", bundleURL: bundle, manifest: stampedNoSource)
        #expect(LibraryEntryDisplay.listTitle(for: stampedEntry, showsAITitle: true) == "Planning and roadmap")
        #expect(LibraryEntryDisplay.listTitle(for: stampedEntry, showsAITitle: false) == "Recording 18 May 2026 at 09:00")

        var aiOnly = base
        aiOnly.aiTitle = "Planning and roadmap"
        let aiEntry = LibraryEntry(id: "e", bundleURL: bundle, manifest: aiOnly)
        #expect(LibraryEntryDisplay.listTitle(for: aiEntry, showsAITitle: true) == "Planning and roadmap")
        #expect(LibraryEntryDisplay.listTitle(for: aiEntry, showsAITitle: false) == "meeting")
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

    /// A pin or a rename ticks the library version for every row, so the version cannot be what a row is kept on.
    @Test("row displays outlive the library version and go only when their entry leaves")
    func displayCacheKeepsRowsUntilTheirEntryLeaves() {
        let entry = display().entry
        let other = LibraryEntry(
            id: "other",
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/other.parola"),
            manifest: entry.manifest
        )
        var cache = LibraryRowDisplayCache()

        _ = cache.display(for: entry)
        _ = cache.display(for: other)
        #expect(cache.displays.count == 2)

        cache.prune(keeping: [entry.id, other.id])
        #expect(cache.displays.count == 2)

        cache.prune(keeping: [entry.id])
        #expect(cache.displays.keys.sorted() == ["e"])
    }

    /// A view that shows a subset (Home's recents, a filtered category) must not let the rest of the library pile up.
    @Test("pruning to a subset drops the rows that fell outside it")
    func pruneToASubsetDropsTheRest() {
        let a = LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/a.parola"), manifest: display().entry.manifest)
        let b = LibraryEntry(id: "b", bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/b.parola"), manifest: display().entry.manifest)
        let c = LibraryEntry(id: "c", bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/c.parola"), manifest: display().entry.manifest)
        var cache = LibraryRowDisplayCache()

        _ = cache.display(for: a)
        _ = cache.display(for: b)
        _ = cache.display(for: c)
        #expect(cache.displays.count == 3)

        cache.prune(keeping: [a.id, b.id])
        #expect(cache.displays.keys.sorted() == ["a", "b"])
    }

    /// The library case, where "kept" is the whole library and outnumbers the handful of rows ever rendered.
    @Test("pruning still drops a row whose entry left even when the kept set is larger than the cache")
    func pruneDropsALeftEntryEvenWhenTheKeptSetIsLarger() {
        let a = LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/a.parola"), manifest: display().entry.manifest)
        var cache = LibraryRowDisplayCache()

        _ = cache.display(for: a)
        #expect(cache.displays.count == 1)

        cache.prune(keeping: ["other-1", "other-2", "other-3"])
        #expect(cache.displays.isEmpty)
    }

    /// The index fills in after the rows are already on screen, and a cached row would keep the blank.
    @Test("an entry the index has just reached drops its cached row")
    func displayCacheFollowsTheIndex() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()

        #expect(cache.display(for: entry, excerpt: nil).excerpt == nil)
        #expect(cache.display(for: entry, excerpt: "Prime parole.").excerpt == "Prime parole.")
        #expect(cache.displays.count == 1)
    }

    /// Row strings are formatted through `AppFormat.locale`, which follows the system, and no entry changes when it does.
    @Test("clearing the cache drops every row so a locale change can reformat them")
    func displayCacheClearsWholesale() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()
        _ = cache.display(for: entry, excerpt: "Prime parole.")
        #expect(cache.displays.count == 1)

        cache.removeAll()
        #expect(cache.displays.isEmpty)

        #expect(cache.display(for: entry, excerpt: "Prime parole.").excerpt == "Prime parole.")
        #expect(cache.displays.count == 1)
    }

    @Test("a cached display is handed back rather than formatted again")
    func displayCacheReturnsTheSameRow() {
        let entry = display().entry
        var cache = LibraryRowDisplayCache()

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

    @Test("a Recently Deleted row is named through the same resolver as every other list")
    func recentlyDeletedRowUsesTheResolver() {
        var manifest = ParolaDocument.Manifest(
            createdAt: date, originalAudioName: "call.wav", modelName: "stub", language: "en"
        )
        manifest.title = "Grocery list"
        manifest.titleSource = .user
        manifest.aiTitle = "Weekly shopping"
        manifest.deletedAt = date
        let entry = LibraryEntry(
            id: "e", bundleURL: URL(fileURLWithPath: "/tmp/LibraryEntryDisplayTests/e.parola"), manifest: manifest
        )

        var cache = LibraryRowDisplayCache()
        let row = cache.display(for: entry, date: entry.deletedAt, dateLabel: "Deleted 12 Sep", showsAITitle: true)

        #expect(row.title == "Grocery list")
    }
}
