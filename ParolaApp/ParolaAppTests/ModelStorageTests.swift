import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

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

    private func makeModel() async -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("model-storage"))
        await model.awaitModelListRefresh()
        await model.awaitSupersededCopiesRefresh()
        return model
    }

    private func size(_ url: URL, in store: ModelStore) throws -> Int64 {
        try Int64(#require(store.sizeOnDisk(at: url)))
    }

    @Test("an earlier download counts toward the bytes on disk and is reported on its own")
    func summaryIncludesTheEarlierDownload() throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }

        let scan = temp.store.scan()
        let models = scan.listedCatalog + scan.installed.filter { entry in
            !scan.listedCatalog.contains { $0.name == entry.name }
        }
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

    @Test("a refresh lists the earlier downloads with their measured size")
    func refreshListsEarlierDownloads() async throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let model = await makeModel()

        model.refreshSupersededCopies(in: temp.store)
        await model.awaitSupersededCopiesRefresh()

        let leftoverBytes = try size(temp.leftover, in: temp.store)
        #expect(model.supersededCopies.map(\.url.standardizedFileURL) == [temp.leftover.standardizedFileURL])
        #expect(model.supersededCopies.first?.bytes == leftoverBytes)
    }

    @Test("reclaiming an earlier download removes only it and leaves the live install")
    func reclaimRemovesOnlyTheLeftover() async throws {
        let temp = try makeStore()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let model = await makeModel()
        model.supersededCopies = AppModel.supersededCopies(in: temp.store)
        let copy = try #require(model.supersededCopies.first)

        let task = try #require(model.reclaimSupersededCopy(Self.turbo, in: temp.store))
        #expect(model.isReclaiming(copy))
        #expect(model.reclaimSupersededCopy(Self.turbo, in: temp.store) == nil)
        await task.value

        #expect(!FileManager.default.fileExists(atPath: temp.leftover.path))
        #expect(FileManager.default.fileExists(atPath: temp.live.path))
        #expect(temp.store.isInstalled(Self.turbo))
        #expect(!model.isReclaiming(copy))
        #expect(model.modelActionError == nil)
        #expect(!model.supersededCopies.contains { $0.url == copy.url })
    }

    @Test("a reclaim that fails says so and frees the row")
    func failedReclaimReportsTheError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel()
        let copy = SupersededCopy(
            variantID: Self.turbo,
            displayName: "Whisper Large v3 Turbo",
            url: root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo"),
            bytes: 1
        )
        model.supersededCopies = [copy]

        let task = try #require(model.reclaimSupersededCopy(Self.turbo, in: ModelStore(modelsDirectory: root)))
        await task.value

        #expect(!model.isReclaiming(copy))
        #expect(model.modelActionError?.contains("Whisper Large v3 Turbo") == true)
    }

    @Test("an earlier download reads as deleting while its model is being deleted")
    func deletingTheModelCoversItsEarlierDownload() async {
        let model = await makeModel()
        let copy = SupersededCopy(
            variantID: Self.turbo,
            displayName: "Whisper Large v3 Turbo",
            url: URL(fileURLWithPath: "/tmp/leftover"),
            bytes: 1
        )
        model.supersededCopies = [copy]
        model.modelsBeingDeleted = [Self.turbo]

        #expect(model.isReclaiming(copy))
        #expect(model.reclaimSupersededCopy(Self.turbo) == nil)
    }
}
