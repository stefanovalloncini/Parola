import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Batch progress")
struct BatchProgressTests {

    private static func makeJob(_ name: String, _ status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/BatchProgressTests/\(name).wav"), status: status)
    }

    @Test("counts completed jobs against the whole batch")
    func countsCompleted() {
        let jobs = [Self.makeJob("a", .done), Self.makeJob("b", .transcribing), Self.makeJob("c", .pending)]
        let counts = BatchProgress.counts(for: jobs)
        #expect(counts?.finished == 1)
        #expect(counts?.total == 3)
    }

    @Test("counts a failed job as neither finished nor gone")
    func countsFailed() {
        let jobs = [Self.makeJob("a", .failed), Self.makeJob("b", .done), Self.makeJob("c", .transcribing)]
        let counts = BatchProgress.counts(for: jobs)
        #expect(counts?.finished == 1)
        #expect(counts?.total == 3)
    }

    @Test("hides once nothing is queued or running")
    func hidesWhenSettled() {
        #expect(BatchProgress.counts(for: [Self.makeJob("a", .done), Self.makeJob("b", .failed)]) == nil)
        #expect(BatchProgress.counts(for: []) == nil)
    }

    @Test("the files caption hides for an empty batch and pluralizes once settled")
    func filesCaptionSettled() {
        let english = Locale(identifier: "en_US")
        #expect(BatchProgress.headerLabel(for: [], locale: english) == nil)
        #expect(BatchProgress.headerLabel(for: [Self.makeJob("a", .done)], locale: english)?.text == "1 file")
        let three = [Self.makeJob("a", .done), Self.makeJob("b", .done), Self.makeJob("c", .failed)]
        #expect(BatchProgress.headerLabel(for: three, locale: english)?.text == "3 files")
        #expect(BatchProgress.headerLabel(for: three, locale: english)?.isProgress == false)
    }

    @Test("the files caption folds in the finished count while jobs are pending or running")
    func filesCaptionRunning() {
        let english = Locale(identifier: "en_US")
        let jobs = [Self.makeJob("a", .done), Self.makeJob("b", .pending), Self.makeJob("c", .transcribing)]
        #expect(BatchProgress.headerLabel(for: jobs, locale: english)?.text == "1 of 3 files")
        #expect(BatchProgress.headerLabel(for: [Self.makeJob("a", .pending)], locale: english)?.text == "0 of 1 file")
        #expect(BatchProgress.headerLabel(for: jobs, locale: english)?.isProgress == true)
    }

    @Test("one pass sorts the queue into its statuses, each in queue order")
    func bucketsKeepQueueOrder() {
        let jobs = [
            Self.makeJob("a", .done), Self.makeJob("b", .pending), Self.makeJob("c", .done),
            Self.makeJob("d", .transcribing), Self.makeJob("e", .pending),
        ]
        let buckets = BatchJobBuckets(jobs)
        #expect(buckets.jobs(.done).map(\.displayName) == ["a", "c"])
        #expect(buckets.jobs(.pending).map(\.displayName) == ["b", "e"])
        #expect(buckets.jobs(.transcribing).map(\.displayName) == ["d"])
        #expect(buckets.jobs(.failed).isEmpty)
        #expect(buckets.hasFinished)
        #expect(!buckets.holdsOnlyRunningJobs)
    }

    @Test("a queue of running and waiting jobs has nothing finished to clear")
    func bucketsWithoutFinishedJobs() {
        #expect(!BatchJobBuckets([Self.makeJob("a", .pending)]).hasFinished)
        #expect(BatchJobBuckets([Self.makeJob("a", .transcribing)]).holdsOnlyRunningJobs)
        #expect(BatchJobBuckets().holdsOnlyRunningJobs)
        #expect(BatchJobBuckets([Self.makeJob("a", .cancelled)]).hasFinished)
    }
}
