import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func makeSilentWAV(seconds: Double, label: String) throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * seconds)
    let dataBytes = frames * channels * bytesPerSample
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
    le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
    le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
    ascii("data"); le32(UInt32(dataBytes))
    data.append(Data(count: dataBytes))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-duration-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

@MainActor
@Suite("Entry duration")
struct EntryDurationTests {

    private func makeModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("duration"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ContinuousClock()
        )
        return AppModel(bootstrap: bootstrap)
    }

    private func seedEntry(
        in model: AppModel,
        mediaSeconds: Double,
        transcriptDuration: Double?,
        text: String
    ) async throws -> LibraryEntry {
        let audio = try makeSilentWAV(seconds: mediaSeconds, label: text)
        defer { try? FileManager.default.removeItem(at: audio) }
        let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        return try await seed.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub",
                durationSeconds: transcriptDuration
            ),
            audioSource: audio,
            category: .transcription
        )
    }

    private func waitUntil(timeoutMs: Int = 10_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    private func openEntry(_ id: LibraryEntry.ID, in model: AppModel) async -> Bool {
        model.loadEntry(id)
        return await waitUntil { model.selectedEntryID == id && model.player != nil }
    }

    private func manifest(of entry: LibraryEntry) throws -> ParolaDocument.Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: entry.bundleURL.appendingPathComponent("manifest.json"))
        return try decoder.decode(ParolaDocument.Manifest.self, from: data)
    }

    private func persistedDurations(of entry: LibraryEntry) throws -> (transcript: Double?, manifest: Double?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcriptData = try Data(contentsOf: entry.bundleURL.appendingPathComponent("transcript.json"))
        let transcript = try decoder.decode(Transcript.self, from: transcriptData)
        return (transcript.durationSeconds, try manifest(of: entry).durationSeconds)
    }

    @Test("an entry with no recorded duration takes it from its own audio")
    func durationFilledFromOwnAudio() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 4, transcriptDuration: nil, text: "long take")

        #expect(await openEntry(entry.id, in: model))
        let filled = await waitUntil { model.transcript?.durationSeconds != nil }
        #expect(filled)
        #expect(abs((model.transcript?.durationSeconds ?? 0) - 4) < 0.05)
    }

    @Test("opening a shorter entry after a longer one shows the shorter duration")
    func shorterEntryKeepsItsOwnDuration() async throws {
        let model = makeModel()
        let long = try await seedEntry(in: model, mediaSeconds: 4, transcriptDuration: nil, text: "long take")
        let short = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 1, text: "short take")

        #expect(await openEntry(long.id, in: model))
        let transcriptWait = await waitUntil { model.transcript?.durationSeconds != nil }
        #expect(transcriptWait)

        #expect(await openEntry(short.id, in: model))
        let settled = await waitUntil { abs((model.transcript?.durationSeconds ?? 0) - 1) < 0.05 }
        #expect(settled, "duration was \(String(describing: model.transcript?.durationSeconds)), expected the short entry's 1s")
    }

    @Test("navigating away never writes another entry's duration into the bundle")
    func navigationLeavesPersistedDurationAlone() async throws {
        let model = makeModel()
        let long = try await seedEntry(in: model, mediaSeconds: 4, transcriptDuration: nil, text: "long take")
        let short = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 1, text: "short take")

        #expect(await openEntry(long.id, in: model))
        let transcriptWait = await waitUntil { model.transcript?.durationSeconds != nil }
        #expect(transcriptWait)
        #expect(await openEntry(short.id, in: model))
        #expect(await openEntry(long.id, in: model))
        #expect(await openEntry(short.id, in: model))

        let durations = try persistedDurations(of: short)
        #expect(abs((durations.transcript ?? 0) - 1) < 0.05, "transcript.json says \(String(describing: durations.transcript))")
        #expect(abs((durations.manifest ?? 0) - 1) < 0.05, "manifest says \(String(describing: durations.manifest))")
    }

    @Test("a recorded duration that outruns the audio is corrected on load")
    func staleLongerDurationIsCorrected() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")

        #expect(await openEntry(entry.id, in: model))
        let healed = await waitUntil { abs((model.transcript?.durationSeconds ?? 0) - 1) < 0.05 }
        #expect(healed, "duration was \(String(describing: model.transcript?.durationSeconds))")
    }

    @Test("the corrected duration reaches the manifest and leaves the transcript alone")
    func correctedDurationReachesTheManifest() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")
        let transcriptURL = entry.bundleURL.appendingPathComponent("transcript.json")
        let transcriptBefore = try Data(contentsOf: transcriptURL)
        let updatedAtBefore = try manifest(of: entry).updatedAt

        #expect(await openEntry(entry.id, in: model))
        let persisted = await waitUntil {
            let stored = (try? self.persistedDurations(of: entry).manifest) ?? nil
            return abs((stored ?? 0) - 1) < 0.05
        }

        let stored = try manifest(of: entry)
        let transcriptAfter = try Data(contentsOf: transcriptURL)
        #expect(persisted, "manifest says \(String(describing: stored.durationSeconds))")
        #expect(transcriptAfter == transcriptBefore, "transcript.json was rewritten")
        #expect(stored.updatedAt == updatedAtBefore)
    }

    @Test("the corrected duration goes through the store, so a refresh keeps it", .timeLimit(.minutes(1)))
    func correctedDurationSurvivesARefresh() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")
        await model.library.dropCaches()

        #expect(await openEntry(entry.id, in: model))
        let absWait = await waitUntil { abs((model.libraryEntry(id: entry.id)?.durationSeconds ?? 0) - 1) < 0.05 }
        #expect(absWait)
        let listed = await model.library.list().first { $0.id == entry.id }
        await model.refreshLibraryAndWait()

        #expect(abs((listed?.durationSeconds ?? 0) - 1) < 0.05, "the store still lists \(String(describing: listed?.durationSeconds))")
        #expect(abs((model.libraryEntry(id: entry.id)?.durationSeconds ?? 0) - 1) < 0.05, "the refresh put the stale duration back")
    }

    @Test("an entry whose manifest already holds the corrected duration is not written again", .timeLimit(.minutes(1)))
    func secondOpenWritesNoDuration() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")
        await model.library.dropCaches()
        // Inside the tolerance but not what the media measures, so a second write would show.
        try await model.library.setDurationSeconds(1.03, for: entry.id)
        await model.refreshLibraryAndWait()

        #expect(await openEntry(entry.id, in: model))
        let absWait = await waitUntil { abs((model.transcript?.durationSeconds ?? 0) - 1) < 0.02 }
        #expect(absWait)
        await settle()

        #expect(try manifest(of: entry).durationSeconds == 1.03)
    }

    @Test("a viewer window shows the corrected duration, not the one transcript.json kept", .timeLimit(.minutes(1)))
    func viewerUsesTheCorrectedDuration() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")
        await model.library.dropCaches()
        try await model.library.setDurationSeconds(1, for: entry.id)
        await model.refreshLibraryAndWait()

        let session = model.entryWindowSession(for: entry.id)
        await session.loadTask?.value

        #expect(session.durationSeconds == 1)
    }

    @Test("the corrected duration reaches the row the list is drawing")
    func correctedDurationReachesTheLibraryRow() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, mediaSeconds: 1, transcriptDuration: 2134.272, text: "corrupted take")

        #expect(await openEntry(entry.id, in: model))
        let patched = await waitUntil {
            abs((model.libraryEntry(id: entry.id)?.durationSeconds ?? 0) - 1) < 0.05
        }

        #expect(
            patched,
            "row says \(String(describing: model.libraryEntry(id: entry.id)?.durationSeconds))"
        )
    }
}
