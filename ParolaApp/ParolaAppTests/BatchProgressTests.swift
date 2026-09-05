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
        #expect(BatchProgress.label(for: []) == nil)
    }
}
