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

    @Test("fallback title carries the creation date")
    func fallbackCarriesDate() {
        let title = LibraryEntryDisplay.title(raw: "6E1B2020-2CB5-4359-A6B2-CBE5B9C25199", createdAt: date)
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        #expect(title.contains(stamp))
    }

    private func display(lastOpenedAt: Date? = nil, labels: [String] = [], pinned: Bool = false) -> LibraryRowDisplay {
        let manifest = ParolaDocument.Manifest(
            createdAt: date,
            originalAudioName: "Weekly sync.m4a",
            modelName: "stub",
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
        return LibraryRowDisplay(entry: entry, sizeBytes: nil)
    }

    @Test("the row's relative and hover strings are formatted with the entry, not with every cell")
    func rowStringsAreFormattedOnce() {
        #expect(display().lastOpened == nil)

        let opened = date.addingTimeInterval(3600)
        let row = display(lastOpenedAt: opened, labels: ["work", "urgent"], pinned: true)
        #expect(row.lastOpened == AppFormat.relativeDate(opened))

        let lines = row.tooltip.split(separator: "\n").map(String.init)
        #expect(lines.first == "Weekly sync")
        #expect(lines.contains("Labels: work, urgent"))
        #expect(lines.last == "Pinned")
    }
}
