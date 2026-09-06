import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Queue count")
struct QueueCountTests {

    private static func makeJob(_ name: String, _ status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/QueueCountTests/\(name).wav"), status: status)
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("queue-count"))
    }

    @Test("hides once nothing is active")
    func hidesWhenIdle() {
        #expect(QueueCount.label(for: []) == nil)
        #expect(QueueCount.label(for: [Self.makeJob("a", .done)]) == nil)
    }

    @Test("counts pending and transcribing jobs against the English wording")
    func wording() {
        let english = Locale(identifier: "en_US")
        let one = [Self.makeJob("a", .pending)]
        #expect(QueueCount.label(for: one, locale: english) == "1 in queue")

        let three = [Self.makeJob("a", .pending), Self.makeJob("b", .transcribing), Self.makeJob("c", .pending)]
        #expect(QueueCount.label(for: three, locale: english) == "3 in queue")
    }

    @Test("matches the sidebar badge for the same jobs")
    func matchesBadge() {
        let jobs = [Self.makeJob("a", .pending), Self.makeJob("b", .transcribing), Self.makeJob("c", .done)]
        let model = makeModel()

        model.batchJobs = jobs

        #expect(model.activeBatchJobCount == QueueCount.count(for: jobs))
        #expect(model.activeBatchJobCount == 2)
    }
}
