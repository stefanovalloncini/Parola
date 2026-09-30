import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
private final class Finished {
    var value = false
}

/// No test here hands `ModelStore.shared` to a delete path: in the test host it is the real model store.
@MainActor
@Suite("Model storage", .serialized)
struct ModelStorageTests {
    private static let turbo = "openai_whisper-large-v3_turbo"

    private struct TempStore {
        let root: URL
        let store: ModelStore
        let live: URL
        let leftover: URL
        let orphan: URL
    }

    private func makeStore() throws -> TempStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(modelsDirectory: root)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let live = store.installedURL(for: Self.turbo)
        let leftover = models.appendingPathComponent(
            "argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo", isDirectory: true
        )
        let orphan = models.appendingPathComponent("FluidInference/some-other-model", isDirectory: true)
        for (folder, bytes) in [(live, 40_000), (leftover, 120_000), (orphan, 8_000)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent("weights.bin"))
        }
        return TempStore(root: root, store: store, live: live, leftover: leftover, orphan: orphan)
    }

    /// Awaits an unstructured task with a deadline: on timeout `waitUntil` records the Issue and the wait is cancelled.
    private func finishes(
        timeoutMs: Int = 5_000,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        let finished = Finished()
        let task = Task { @MainActor in
            await work()
            finished.value = true
        }
        let done = await waitUntil(timeoutMs: timeoutMs, sourceLocation: sourceLocation) { finished.value }
        if !done { task.cancel() }
        return done
    }

    /// Lets the launch scan and its copy refresh land first, so neither overwrites what a test sets.
    private func makeModel() async throws -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("model-storage"))
        let scanned = await finishes { await model.awaitModelListRefresh() }
        try #require(scanned)
        let measured = await finishes { await model.awaitSupersededCopiesRefresh() }
        try #require(measured)
        return model
    }

    private func size(_ url: URL, in store: ModelStore) throws -> Int64 {
        try Int64(#require(store.sizeOnDisk(at: url)))
    }

    private func missingCopy(under root: URL) -> SupersededCopy {
        SupersededCopy(
            variantID: Self.turbo,
            displayName: "Whisper Large v3 Turbo",
            url: root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo"),
            bytes: 1
        )
    }

    @Test("an earlier download counts toward the bytes on disk and is reported on its own")
    func summaryIncludesTheEarlierDownload() throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }

        let scan = temp.store.scan()
        let listedNames = Set(scan.listedCatalog.map(\.name))
        let models = scan.listedCatalog + scan.installed.filter { !listedNames.contains($0.name) }
        var sizes: [String: Int64] = [:]
        for info in models where info.isInstalled {
            if let url = info.installedURL { sizes[info.name] = try size(url, in: temp.store) }
        }
        let copies = AppModel.supersededCopies(in: temp.store)
        let summary = AppModel.modelsDiskSummary(models: models, sizes: sizes, earlier: copies)

        let leftoverBytes = try size(temp.leftover, in: temp.store)
        let otherBytes = try size(temp.live, in: temp.store) + size(temp.orphan, in: temp.store)
        #expect(copies.map(\.variantID) == [Self.turbo])
        #expect(copies.first?.displayName == "Whisper Large v3 Turbo")
        #expect(copies.first?.bytes == leftoverBytes)
        #expect(summary.count == 1)
        #expect(summary.earlierBytes == leftoverBytes)
        #expect(summary.bytes == otherBytes + leftoverBytes)
    }

    @Test("the usage line names the earlier downloads only when there are some")
    func usageTextMentionsEarlierDownloads() {
        let clean = ModelsDiskSummary(count: 8, bytes: 7_500_000_000, earlierBytes: 0)
        #expect(clean.usageText == "8 installed · \(AppFormat.byteSize(Int64(7_500_000_000)))")

        let withLeftovers = ModelsDiskSummary(count: 8, bytes: 13_300_000_000, earlierBytes: 5_800_000_000)
        #expect(withLeftovers.usageText == "8 installed · \(AppFormat.byteSize(Int64(13_300_000_000))) · "
            + "\(AppFormat.byteSize(Int64(5_800_000_000))) in earlier downloads")
    }

    @Test("the usage line and the earlier-download strings read in Italian, with a singular for one model")
    func italianStrings() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let size = "3 GB"
        let name = "Whisper Large v3 Turbo"
        let reason = "disco pieno"

        #expect(String(localized: "\(1) installed · \(size)", bundle: bundle) == "1 installato · 3 GB")
        #expect(String(localized: "\(8) installed · \(size)", bundle: bundle) == "8 installati · 3 GB")
        #expect(String(localized: "\(size) in earlier downloads", bundle: bundle) == "3 GB in download precedenti")
        #expect(String(localized: "Delete the earlier download of \(name)?", bundle: bundle)
            == "Eliminare il download precedente di Whisper Large v3 Turbo?")
        #expect(String(localized: "Could not delete \(name): \(reason)", bundle: bundle)
            == "Impossibile eliminare Whisper Large v3 Turbo: disco pieno")
        #expect(String(
            localized: "This will remove \(size) from disk, including an earlier download. You can re-download the model later.",
            bundle: bundle
        ) == "Verrà rimosso 3 GB dal disco, compreso un download precedente. Potrai riscaricare il modello più tardi.")
    }

    @Test("a refresh lists the earlier downloads with their measured size")
    func refreshListsEarlierDownloads() async throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let model = try await makeModel()

        model.refreshSupersededCopies(in: temp.store)
        let refreshed = await finishes { await model.awaitSupersededCopiesRefresh() }
        try #require(refreshed)

        let leftoverBytes = try size(temp.leftover, in: temp.store)
        #expect(model.supersededCopies.map(\.url.standardizedFileURL) == [temp.leftover.standardizedFileURL])
        #expect(model.supersededCopies.first?.bytes == leftoverBytes)
    }

    @Test("reclaiming an earlier download removes only it and leaves the live install")
    func reclaimRemovesOnlyTheLeftover() async throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let model = try await makeModel()
        model.supersededCopies = AppModel.supersededCopies(in: temp.store)
        let copy = try #require(model.supersededCopies.first)

        let started = model.reclaimSupersededCopy(Self.turbo, in: temp.store) != nil
        try #require(started)
        #expect(model.isReclaiming(copy))
        #expect(model.isDeletingModel(Self.turbo))
        let startedTwice = model.reclaimSupersededCopy(Self.turbo, in: temp.store) != nil
        #expect(!startedTwice)
        let finished = await waitUntil { !model.isReclaiming(copy) }
        try #require(finished)

        let rowRemains = model.supersededCopies.contains { $0.url == copy.url }
        #expect(!FileManager.default.fileExists(atPath: temp.leftover.path))
        #expect(FileManager.default.fileExists(atPath: temp.live.path))
        #expect(temp.store.isInstalled(Self.turbo))
        #expect(!model.isDeletingModel(Self.turbo))
        #expect(model.modelActionError == nil)
        #expect(!rowRemains)
    }

    @Test("a copy that is already gone counts as cleared")
    func reclaimOfAMissingCopySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let copy = missingCopy(under: root)
        model.supersededCopies = [copy]

        let started = model.reclaimSupersededCopy(Self.turbo, in: ModelStore(modelsDirectory: root)) != nil
        try #require(started)
        let finished = await waitUntil { !model.isReclaiming(copy) }
        try #require(finished)

        let rowRemains = model.supersededCopies.contains { $0.url == copy.url }
        #expect(model.modelActionError == nil)
        #expect(!rowRemains)
    }

    @Test("a reclaim the disk refuses says why and leaves the copy in place")
    func failedReclaimReportsTheError() async throws {
        let temp = try makeStore()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temp.leftover.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.leftover.path)
            try? FileManager.default.removeItem(at: temp.root)
        }
        let model = try await makeModel()
        model.supersededCopies = AppModel.supersededCopies(in: temp.store)
        let copy = try #require(model.supersededCopies.first)

        let started = model.reclaimSupersededCopy(Self.turbo, in: temp.store) != nil
        try #require(started)
        let finished = await waitUntil { !model.isReclaiming(copy) }
        try #require(finished)

        let message = model.modelActionError ?? ""
        #expect(message.contains("Whisper Large v3 Turbo"))
        #expect(FileManager.default.fileExists(atPath: temp.leftover.appendingPathComponent("weights.bin").path))
    }

    @Test("an earlier download reads as deleting while its model is being deleted")
    func deletingTheModelCoversItsEarlierDownload() async throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let model = try await makeModel()
        model.supersededCopies = AppModel.supersededCopies(in: temp.store)
        let copy = try #require(model.supersededCopies.first)
        model.modelsBeingDeleted = [Self.turbo]

        try #require(model.isReclaiming(copy))
        let started = model.reclaimSupersededCopy(Self.turbo, in: temp.store) != nil
        #expect(!started)
        #expect(FileManager.default.fileExists(atPath: temp.leftover.path))
    }

    @Test("a model reads as busy while one of its earlier copies is being cleared")
    func clearingACopyMarksItsModelBusy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        let model = try await makeModel()
        let copy = missingCopy(under: root)
        model.supersededCopies = [copy]
        model.modelsBeingDeleted = [copy.id]

        #expect(model.isDeletingModel(Self.turbo))
        #expect(!model.isDeletingModel("openai_whisper-tiny"))
    }
}
