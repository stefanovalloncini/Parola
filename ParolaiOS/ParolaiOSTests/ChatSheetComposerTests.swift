import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Chat sheet send gate")
struct ChatSheetComposerTests {
    @Test("a real prompt enables send")
    func realPromptEnables() {
        #expect(ChatSheet.isSendDisabled(input: "What is this about?", isSending: false) == false)
    }

    @Test("empty input disables send")
    func emptyDisables() {
        #expect(ChatSheet.isSendDisabled(input: "", isSending: false) == true)
    }

    @Test("spaces-only input disables send")
    func spacesDisable() {
        #expect(ChatSheet.isSendDisabled(input: "   ", isSending: false) == true)
    }

    @Test("newline-only input disables send")
    func newlinesDisable() {
        #expect(ChatSheet.isSendDisabled(input: "\n\n", isSending: false) == true)
    }

    @Test("mixed whitespace and newlines disable send")
    func mixedWhitespaceDisables() {
        #expect(ChatSheet.isSendDisabled(input: " \n \t\n", isSending: false) == true)
    }

    @Test("a send already in flight disables send")
    func sendingDisables() {
        #expect(ChatSheet.isSendDisabled(input: "follow up question", isSending: true) == true)
    }

    @Test("a chat's digest is kept as the entry's summary, and the chapters the entry had stay")
    func digestIsKeptWithExistingChapters() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parola-ios-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryStore(libraryURL: dir, extraIndexer: nil)
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        transcript.chapters = [Chapter(title: "Generated", start: 0)]
        let entry = try await library.add(transcript: transcript, audioSource: nil)

        let saved = await ChatSheet.keep(
            digest: Summary(text: "the digest", chapters: [Chapter(title: "Digest start", start: 0)]),
            for: entry.id, in: transcript, library: library
        )

        #expect(saved.summary?.text == "the digest")
        #expect(saved.chapters?.map(\.title) == ["Generated"])
        let stored = try await library.load(entry.id).document.transcript
        #expect(stored.summary?.text == "the digest")
        #expect(stored.summary?.chapters.map(\.title) == ["Generated"])
        #expect(stored.chapters?.map(\.title) == ["Generated"])
    }

    @Test("with no chapters of its own the entry takes the digest's")
    func digestBringsChaptersWhenNoneExist() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parola-ios-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryStore(libraryURL: dir, extraIndexer: nil)
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        let entry = try await library.add(transcript: transcript, audioSource: nil)

        let saved = await ChatSheet.keep(
            digest: Summary(text: "the digest", chapters: [Chapter(title: "Digest start", start: 0)]),
            for: entry.id, in: transcript, library: library
        )

        #expect(saved.chapters?.map(\.title) == ["Digest start"])
        #expect(try await library.load(entry.id).document.transcript.chapters?.map(\.title) == ["Digest start"])
    }
}
