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
        #expect(BatchProgress.label(for: jobs) == "1 of 3")
    }

    @Test("hides once nothing is queued or running")
    func hidesWhenSettled() {
        #expect(BatchProgress.label(for: [Self.makeJob("a", .done), Self.makeJob("b", .failed)]) == nil)
        #expect(BatchProgress.label(for: []) == nil)
    }
}
