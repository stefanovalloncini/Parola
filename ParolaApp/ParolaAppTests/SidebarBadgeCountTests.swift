import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

// @unchecked: only written from the observation callback, which the model raises on the main actor.
private final class InvalidationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
@Suite("Sidebar badge counts")
struct SidebarBadgeCountTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// AppModel's init kicks off a library refresh; letting it land keeps it from clobbering the seeded entries.
    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("badges")
        )
        await model.libraryRefreshTask?.value
        return model
    }

    private func entry(_ id: String, title: String? = nil, pinned: Bool = false) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate,
            originalAudioName: "\(id).m4a",
            title: title ?? id.uppercased(),
            modelName: "stub",
            language: "en",
            pinned: pinned
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/SidebarBadgeCountTests/\(id).parola"),
            manifest: manifest
        )
    }

    private func job(_ name: String, status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/SidebarBadgeCountTests/\(name).wav"), status: status)
    }

    @Test("the queue badge follows a status changed in place")
    func queueBadgeFollowsInPlaceStatus() async {
        let model = await makeModel()
        model.batchJobs = [
            job("a", status: .pending),
            job("b", status: .transcribing),
            job("c", status: .done),
        ]
        #expect(model.activeBatchJobCount == 2)

        model.batchJobs[1].status = .done
        #expect(model.activeBatchJobCount == 1)

        model.batchJobs[0].status = .failed
        #expect(model.activeBatchJobCount == 0)
    }

    @Test("a progress tick that leaves the count alone does not invalidate the badge")
    func queueBadgeSkipsUnchangedCount() async {
        let model = await makeModel()
        model.batchJobs = [job("a", status: .transcribing)]
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.activeBatchJobCount
        } onChange: {
            invalidated.fired = true
        }

        await model.handleBatchEvent(.progress(jobID: model.batchJobs[0].id, fraction: 0.4))
        await model.handleBatchEvent(.progress(jobID: model.batchJobs[0].id, fraction: 0.7))
        model.batchJobs[0].segmentCount = 2
        #expect(!invalidated.fired)

        model.batchJobs[0].status = .done
        #expect(invalidated.fired)
    }

    @Test("re-listing the same deleted entries leaves the trash badge alone")
    func deletedBadgeSkipsUnchangedList() async {
        let model = await makeModel()
        model.setDeletedEntries([entry("a"), entry("b")])
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.deletedEntries.count
        } onChange: {
            invalidated.fired = true
        }

        model.setDeletedEntries([entry("a"), entry("b")])
        #expect(!invalidated.fired)

        model.setDeletedEntries([entry("a")])
        #expect(invalidated.fired)
    }

    @Test("a renamed deleted entry still reaches the trash list")
    func deletedListSeesRename() async {
        let model = await makeModel()
        model.setDeletedEntries([entry("a")])

        model.setDeletedEntries([entry("a", title: "Renamed")])

        #expect(model.deletedEntries.first?.title == "Renamed")
    }
}
