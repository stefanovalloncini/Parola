import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library refresh race")
struct LibraryRefreshRaceTests {

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "done")],
            language: "en",
            modelName: "stub"
        )
    }

    /// Keeps the main actor busy so the scan's and the landing's continuations, both queued behind it, run back to back.
    private func holdMainActor(for duration: Duration) {
        Task { @MainActor in
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {}
        }
    }

    @Test("a row landed while the startup scan reads survives the scan")
    func landedRowSurvivesTheStartupScan() async {
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("refresh-race-landing")
        )

        model.land(RunLanding(kind: .salvagedTake, transcript: makeTranscript()))
        holdMainActor(for: .milliseconds(30))

        await awaitGuarded("the landing's steps") { await model.awaitLandingSteps() }
        await awaitGuarded("the startup scan") { await model.libraryRefreshTask?.value }
        #expect(model.libraryEntries.count == 1)
        #expect(model.libraryLoaded)
    }

    @Test("a scan whose snapshot predates a landed row reads again instead of dropping it")
    func staleSnapshotKeepsTheLandedRow() async throws {
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("refresh-race-stale")
        )
        await awaitGuarded("the startup scan") { await model.libraryRefreshTask?.value }

        model.refreshLibrary()
        // One turn of the main actor: the scan has asked the store for its snapshot, so the add below queues behind that read.
        await Task.yield()
        let saved = OSAllocatedUnfairLock<Result<LibraryEntry, any Error>?>(initialState: nil)
        let library = model.library
        let transcript = makeTranscript()
        Task.detached(priority: Task.currentPriority) {
            do {
                let entry = try await library.add(transcript: transcript, audioSource: nil)
                saved.withLock { $0 = .success(entry) }
            } catch {
                saved.withLock { $0 = .failure(error) }
            }
        }
        // Holding the main actor until the add has landed keeps the scan's continuations queued behind the insert below.
        let deadline = ContinuousClock.now + .seconds(10)
        var result: Result<LibraryEntry, any Error>?
        while result == nil, !Task.isCancelled, ContinuousClock.now < deadline { result = saved.withLock { $0 } }
        guard let result else {
            let reason = Task.isCancelled ? "cancelled" : "gave up after 10 seconds"
            Issue.record("\(reason) waiting for the add to land")
            return
        }
        let entry = try result.get()
        model.landLibraryEntry(entry)
        #expect(model.libraryEntries.map(\.id) == [entry.id])

        await awaitGuarded("the scan") { await model.libraryRefreshTask?.value }
        #expect(model.libraryEntries.map(\.id) == [entry.id])
        #expect(model.libraryRefreshes == 2, "the scan reads again inside its own task")
    }

    @Test("a scan whose snapshot predates a delete does not bring the row back")
    func staleSnapshotDoesNotResurrectADeletedRow() async throws {
        let libraryURL = makeTempLibraryURL("refresh-race-delete")
        let seed = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let entry = try await seed.add(transcript: makeTranscript(), audioSource: nil)
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: libraryURL)
        await awaitGuarded("the startup scan") { await model.libraryRefreshTask?.value }
        #expect(model.libraryEntries.map(\.id) == [entry.id])

        model.refreshLibrary()
        _ = await model.library.list()
        model.deleteEntry(entry.id)

        await pollUntil("the delete's own scan to start") { model.libraryRefreshes >= 3 }
        await awaitGuarded("the delete's scan") { await model.libraryRefreshTask?.value }
        #expect(model.libraryEntries.isEmpty)
        #expect(model.deletedEntries.map(\.id) == [entry.id])
    }
}
