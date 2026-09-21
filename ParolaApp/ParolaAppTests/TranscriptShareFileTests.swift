import Foundation
import Testing
@testable import Parola

@Suite("Transcript share file")
struct TranscriptShareFileTests {

    @Test("names the file after the title with a txt extension")
    func namesFileAfterTitle() {
        #expect(TranscriptShareFile.fileName(for: "Team standup") == "Team standup.txt")
    }

    @Test("replaces path separators and colons in the title")
    func sanitizesTitle() {
        #expect(TranscriptShareFile.fileName(for: "a/b: c") == "a-b- c.txt")
    }

    @Test("safeName is the same cleaning without an extension, so other exports can share it")
    func safeNameStripsTheSameCharacters() {
        #expect(TranscriptShareFile.safeName(for: "Recording — 21 Sep 2026 at 2:40") == "Recording — 21 Sep 2026 at 2-40")
        #expect(TranscriptShareFile.safeName(for: "a/b: c") == "a-b- c")
        #expect(TranscriptShareFile.safeName(for: "   ") == "Transcript")
    }

    @Test("an empty title falls back to Transcript")
    func emptyTitleFallsBack() {
        #expect(TranscriptShareFile.fileName(for: "   ") == "Transcript.txt")
    }

    @Test("write puts the text into a txt file named after the title")
    func writeRoundTrip() throws {
        let url = try TranscriptShareFile.write(title: "Interview", text: "Hello there.")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.lastPathComponent == "Interview.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "Hello there.")
    }
}
