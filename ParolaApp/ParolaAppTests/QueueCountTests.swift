import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Queue count")
struct QueueCountTests {

    private static func makeJob(_ name: String, _ status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/QueueCountTests/\(name).wav"), status: status)
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("queue-count"))
    }

    @Test("hides only when the queue is empty")
    func hidesWhenEmpty() {
        let english = Locale(identifier: "en_US")
        #expect(QueueCount.label(for: []) == nil)
        #expect(QueueCount.label(for: [Self.makeJob("a", .done)], locale: english) == "1 file")
        #expect(
            QueueCount.label(for: [Self.makeJob("a", .done), Self.makeJob("b", .failed)], locale: english)
                == "2 files"
        )
    }

    @Test("counts pending and transcribing jobs against the English wording")
    func wording() {
        let english = Locale(identifier: "en_US")
        let one = [Self.makeJob("a", .pending)]
        #expect(QueueCount.label(for: one, locale: english) == "1 in queue")

        let three = [Self.makeJob("a", .pending), Self.makeJob("b", .transcribing), Self.makeJob("c", .pending)]
        #expect(QueueCount.label(for: three, locale: english) == "3 in queue")
    }

    @Test("the Queue page's Resume reads in Italian")
    func resumeIsLocalized() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: String.LocalizationValue("Resume"), bundle: italian) == "Riprendi")
    }

    @Test("matches the sidebar badge for the same jobs")
    func matchesBadge() {
        let jobs = [Self.makeJob("a", .pending), Self.makeJob("b", .transcribing), Self.makeJob("c", .done)]
        let model = makeModel()

        model.batchJobs = jobs

        #expect(model.sidebarActivity == .inProgress(count: QueueCount.count(for: jobs)))
        #expect(model.sidebarActivity?.count == 2)
        #expect(
            QueueCount.label(for: jobs, locale: Locale(identifier: "en_US"))
                == "\(model.sidebarActivity?.count ?? 0) in queue"
        )
    }
}
