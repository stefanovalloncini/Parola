import Foundation
import Testing
@testable import ParolaCore

@Suite("Library summary")
struct LibrarySummaryTests {
    @Test("empty entries returns zero everywhere")
    func empty() {
        let s = LibrarySummary(entries: [])
        #expect(s.total == 0)
        #expect(s.pinned == 0)
        #expect(s.transcriptions == 0)
        #expect(s.meetings == 0)
        #expect(s.dictations == 0)
    }

    @Test("counts entries by category")
    func categoryCounts() {
        let entries = [
            entry(category: .transcription),
            entry(category: .transcription),
            entry(category: .meeting),
            entry(category: .dictation),
            entry(category: .dictation),
            entry(category: .dictation),
        ]
        let s = LibrarySummary(entries: entries)
        #expect(s.total == 6)
        #expect(s.transcriptions == 2)
        #expect(s.meetings == 1)
        #expect(s.dictations == 3)
    }

    @Test("counts pinned entries")
    func pinnedCount() {
        let entries = [
            entry(category: .transcription, pinned: true),
            entry(category: .meeting, pinned: true),
            entry(category: .transcription, pinned: false),
        ]
        let s = LibrarySummary(entries: entries)
        #expect(s.total == 3)
        #expect(s.pinned == 2)
    }

    private func entry(category: EntryCategory, pinned: Bool = false) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            version: 1,
            createdAt: Date(),
            originalAudioName: "test.wav",
            modelName: "tiny",
            language: "en",
            category: category,
            labels: [],
            segmentNotes: [:],
            pinned: pinned
        )
        return LibraryEntry(id: UUID().uuidString, bundleURL: URL(fileURLWithPath: "/tmp"), manifest: manifest)
    }
}
