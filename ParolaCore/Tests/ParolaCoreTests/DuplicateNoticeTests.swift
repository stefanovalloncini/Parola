import Testing
import Foundation
@testable import ParolaCore

@Suite("Duplicate notice", .tags(.fileSystem))
struct DuplicateNoticeTests {
    private let posix = Locale(identifier: "en_US_POSIX")

    private func entry(title: String, model: String, createdAt: Date) -> LibraryEntry {
        LibraryEntry(
            id: "e1",
            bundleURL: URL(fileURLWithPath: "/tmp/e1.parola"),
            manifest: ParolaDocument.Manifest(
                createdAt: createdAt,
                originalAudioName: "\(title).m4a",
                modelName: model,
                language: "en"
            )
        )
    }

    @Test("the notice names the entry, the model and the date")
    func noticeText() {
        let text = DuplicateNotice.text(
            for: entry(
                title: "Board meeting",
                model: "openai_whisper-large-v3_turbo",
                createdAt: Date(timeIntervalSince1970: 1_757_000_000)
            ),
            skipping: false,
            locale: posix
        )
        #expect(text.hasPrefix("Already in the library as Board meeting (openai_whisper-large-v3_turbo, "))
        #expect(text.hasSuffix("); transcribing again"))
    }

    @Test("the skipping notice says so instead")
    func skippingText() {
        let text = DuplicateNotice.text(
            for: entry(title: "Standup", model: "tiny", createdAt: Date(timeIntervalSince1970: 1_757_000_000)),
            skipping: true,
            locale: posix
        )
        #expect(text.hasSuffix("); skipping"))
    }

    @Test("lookup hands back the digest it hashed along with the entry")
    func lookupCarriesTheDigest() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audio = tmp.appendingPathComponent("clip.wav")
        try Data("RIFFnotice".utf8).write(to: audio)

        let store = LibraryStore(libraryURL: tmp.appendingPathComponent("library"), extraIndexer: nil)
        let fresh = await DuplicateNotice.lookup(for: audio, in: store)
        #expect(fresh.digest == (try SourceDigest.compute(contentsOf: audio)))
        #expect(fresh.entry == nil)

        let added = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
                language: "en",
                modelName: "tiny"
            ),
            audioSource: audio
        )
        let second = await DuplicateNotice.lookup(for: audio, in: store)
        #expect(second.entry?.id == added.id)
    }

    @Test("lookups answer every file in the order it came, a few hashes at a time")
    func lookupsKeepInputOrder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-notice-many-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try (0..<7).map { index in
            let url = tmp.appendingPathComponent("clip-\(index).wav")
            try Data("RIFF-\(index)-\(String(repeating: "x", count: index * 1000))".utf8).write(to: url)
            return url
        }
        let missing = tmp.appendingPathComponent("missing.wav")
        let store = LibraryStore(libraryURL: tmp.appendingPathComponent("library"), extraIndexer: nil)
        let known = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
                language: "en",
                modelName: "tiny"
            ),
            audioSource: files[4]
        )

        let lookups = await DuplicateNotice.lookups(for: files + [missing], in: store, width: 2)

        #expect(lookups.count == 8)
        for (url, lookup) in zip(files, lookups) {
            #expect(lookup.digest == (try SourceDigest.compute(contentsOf: url)))
        }
        #expect(lookups.map { $0.entry?.id } == [nil, nil, nil, nil, known.id, nil, nil, nil])
        #expect(lookups[7].digest == nil)
    }

    @Test("a file that cannot be read yields neither digest nor entry")
    func unreadableFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-notice-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LibraryStore(libraryURL: tmp, extraIndexer: nil)

        let lookup = await DuplicateNotice.lookup(for: tmp.appendingPathComponent("gone.wav"), in: store)
        #expect(lookup.digest == nil)
        #expect(lookup.entry == nil)
    }
}
