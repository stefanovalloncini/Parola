import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Library refresh skipping")
struct LibraryRefreshSkipTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String,
        title: String = "Entry",
        pinned: Bool = false,
        labels: [String] = [],
        segmentNotes: [String: String] = [:],
        lastOpenedAt: Date? = nil
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate,
            originalAudioName: "\(title).m4a",
            title: title,
            modelName: "stub",
            language: "en",
            lastOpenedAt: lastOpenedAt,
            labels: labels,
            segmentNotes: segmentNotes,
            pinned: pinned
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryRefreshSkipTests/\(id).parola"),
            manifest: manifest
        )
    }

    /// AppModel's init kicks off a library refresh; letting it land keeps it from clobbering the seeded entries.
    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("refreshskip")
        )
        await model.libraryRefreshTask?.value
        return model
    }

    @Test("an unchanged list leaves the version alone")
    func unchangedListSkipsBump() async {
        let model = await makeModel()
        model.setLibraryEntries([entry(id: "a"), entry(id: "b")])
        let version = model.libraryVersion

        model.setLibraryEntries([entry(id: "a"), entry(id: "b")])

        #expect(model.libraryVersion == version)
    }

    @Test("a new segment note repaints the readers that key off the version")
    func segmentNoteBumpsVersion() async {
        let model = await makeModel()
        model.setLibraryEntries([entry(id: "a")])
        let version = model.libraryVersion

        model.setLibraryEntries([entry(id: "a", segmentNotes: ["3": "check this"])])

        #expect(model.libraryVersion > version)
        #expect(model.libraryEntry(id: "a")?.note(forSegment: 3) == "check this")
    }

    @Test("pinning, renaming, labelling and reordering all bump the version", arguments: [
        "pin", "rename", "label", "reorder", "remove",
    ])
    func mutationsBumpVersion(kind: String) async {
        let model = await makeModel()
        model.setLibraryEntries([entry(id: "a", title: "First"), entry(id: "b", title: "Second")])
        let version = model.libraryVersion

        switch kind {
        case "pin":
            model.setLibraryEntries([entry(id: "a", title: "First", pinned: true), entry(id: "b", title: "Second")])
        case "rename":
            model.setLibraryEntries([entry(id: "a", title: "Renamed"), entry(id: "b", title: "Second")])
        case "label":
            model.setLibraryEntries([entry(id: "a", title: "First", labels: ["work"]), entry(id: "b", title: "Second")])
        case "reorder":
            model.setLibraryEntries([entry(id: "b", title: "Second"), entry(id: "a", title: "First")])
        default:
            model.setLibraryEntries([entry(id: "a", title: "First")])
        }

        #expect(model.libraryVersion > version)
    }

    @Test("a fresh lastOpenedAt is not a change unless the list is sorted by it")
    func lastOpenedAloneIsNotAChange() {
        let opened = Self.baseDate.addingTimeInterval(500)
        let before = [entry(id: "a"), entry(id: "b")]
        let after = [entry(id: "a", lastOpenedAt: opened), entry(id: "b")]

        #expect(AppModel.sameEntries(after, before, comparingLastOpened: false))
        #expect(!AppModel.sameEntries(after, before, comparingLastOpened: true))
        #expect(!AppModel.sameEntries(
            [entry(id: "a", title: "Renamed", lastOpenedAt: opened), entry(id: "b")],
            before,
            comparingLastOpened: false
        ))
    }

    @Test("the last-opened sort still repaints when a row is opened")
    func lastOpenedSortStillRepaints() async {
        let model = await makeModel()
        model.setLibraryEntries([entry(id: "a"), entry(id: "b")])
        let quiet = model.libraryVersion

        model.setLibraryEntries([entry(id: "a", lastOpenedAt: Self.baseDate.addingTimeInterval(500)), entry(id: "b")])
        #expect(model.libraryVersion == quiet)

        model.librarySortOrder = .lastOpened
        let sorting = model.libraryVersion
        model.setLibraryEntries([entry(id: "a", lastOpenedAt: Self.baseDate.addingTimeInterval(900)), entry(id: "b")])

        #expect(model.libraryVersion > sorting)
    }

    @Test("opening an entry repaints the row it just stamped")
    func openingAnEntryRefreshesItsRow() async throws {
        let libraryURL = makeTempLibraryURL("refreshskip-open")
        let seedStore = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: libraryURL
        )
        model.refreshLibrary()
        for _ in 0..<200 where model.libraryEntries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let version = model.libraryVersion

        model.loadEntry(seeded.id)
        // Wait for the write the skipping is about: markOpened has stamped the manifest on disk, and the
        // refresh it triggers has landed. A fixed sleep would pass whether or not the refresh ever ran.
        var stamped = false
        for _ in 0..<400 {
            await model.libraryRefreshTask?.value
            if try manifest(at: seeded.bundleURL).lastOpenedAt != nil { stamped = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.libraryRefreshTask?.value

        #expect(stamped)
        #expect(model.selectedEntryID == seeded.id)
        #expect(model.libraryVersion > version, "the row shows Last opened, so it has to rebuild")
        #expect(model.libraryEntry(id: seeded.id)?.lastOpenedAt != nil)
    }

    private func manifest(at bundleURL: URL) throws -> ParolaDocument.Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ParolaDocument.Manifest.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        )
    }

    @Test("a refresh that finds nothing new leaves the version alone")
    func repeatedRefreshSkipsBump() async throws {
        let libraryURL = makeTempLibraryURL("refreshskip-seeded")
        // Seed before the model exists: its store caches the listing, so a later external write stays invisible.
        let seedStore = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        _ = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: libraryURL
        )

        model.refreshLibrary()
        for _ in 0..<200 where model.libraryEntries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.libraryEntries.count == 1)
        let version = model.libraryVersion

        model.refreshLibrary()
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.libraryVersion == version)
        #expect(model.libraryEntries.count == 1)
    }
}
