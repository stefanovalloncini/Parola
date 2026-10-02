import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// @unchecked is safe: the only state is `opened`/`waiters`, guarded by the lock.
private final class StallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let due = waiters
        waiters = []
        lock.unlock()
        for waiter in due { waiter.resume() }
    }

    /// Deliberately not cancellation-aware: it stands in for a run parked in a blocking read.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

@MainActor
@Suite("Bridge cancel tells the truth")
struct CancelHonestyTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, AutomationCommand) {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("cancel-honesty")
        )
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let command = try #require(server.coreCommands().first { $0.name == "cancel" })
        return (model, server, context, command)
    }

    private func flag(_ value: AutomationValue, _ key: String) -> Bool? {
        guard case .object(let fields) = value, case .bool(let flag)? = fields[key] else { return nil }
        return flag
    }

    @Test("a run that is still parked reports cancelling, not cancelled")
    func parkedRunReportsCancelling() async throws {
        let (model, server, context, command) = try makeRig()
        let gate = StallGate()
        defer { gate.open() }
        model.fileTranscribeTask = Task { await gate.wait() }
        #expect(model.canCancel)

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelling") == true)
        #expect(flag(result, "cancelled") == nil)
        #expect(!model.cancelSettled)
    }

    @Test("a run that unwinds reports cancelled")
    func unwoundRunReportsCancelled() async throws {
        let (model, server, context, command) = try makeRig()
        let gate = StallGate()
        model.fileTranscribeTask = Task { await gate.wait() }
        gate.open()

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == true)
        #expect(model.cancelSettled)
    }

    @Test("a batch run that is still parked reports cancelling too")
    func parkedBatchReportsCancelling() async throws {
        let (model, server, context, command) = try makeRig()
        let gate = StallGate()
        defer { gate.open() }
        model.batchTask = Task { await gate.wait() }
        #expect(model.canCancel)

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelling") == true)
        #expect(flag(result, "cancelled") == nil)
    }

    @Test("a batch run that unwinds reports cancelled")
    func unwoundBatchReportsCancelled() async throws {
        let (model, server, context, command) = try makeRig()
        let gate = StallGate()
        model.batchTask = Task { await gate.wait() }
        gate.open()

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == true)
    }

    @Test("a run left parked by an earlier pass does not taint the next cancel")
    func anOldZombieDoesNotTaintTheNextPass() async throws {
        let (model, server, context, command) = try makeRig()
        let zombie = StallGate()
        defer { zombie.open() }
        model.fileTranscribeTask = Task { await zombie.wait() }
        _ = try await command.handler(AutomationArgs([:]), context)
        #expect(!model.cancelSettled)

        let quick = StallGate()
        model.fileTranscribeTask = Task { await quick.wait() }
        quick.open()
        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == true)
    }

    private func takeRig(_ label: String) throws -> (AppModel, ParolaAutomationServer, AutomationContext, AutomationCommand) {
        let model = makeRecordingModel(label)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let command = try #require(server.coreCommands().first { $0.name == "cancel" })
        return (model, server, context, command)
    }

    @Test("cancel during a take that records leaves it recording, its audio on disk, and says it cancelled nothing")
    func takeIsNotCancelled() async throws {
        let (model, server, context, command) = try takeRig("cancel-honesty-take")
        let file = try await startMeteredTake(model, source: .systemAudio)

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == false)
        #expect(model.recording?.state == .recording)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await model.discardTake()
    }

    @Test("cancel during a take stops a model download beside it and leaves the take")
    func downloadBesideATakeIsCancelled() async throws {
        let (model, server, context, command) = try takeRig("cancel-honesty-download")
        model.modelDownloadOperation = { _, _ in try await Task.sleep(for: .seconds(60)) }
        #expect(model.downloadModel("openai_whisper-tiny"))
        let file = try await startMeteredTake(model)

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == true)
        #expect(model.phase == .idle)
        #expect(model.recording?.state == .recording)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await model.discardTake()
    }

    @Test("nothing in flight still reports cancelled false")
    func idleReportsNothingCancelled() async throws {
        let (model, server, context, command) = try makeRig()
        #expect(!model.canCancel)

        let result = try await command.handler(AutomationArgs([:]), context)
        withExtendedLifetime(server) {}

        #expect(flag(result, "cancelled") == false)
    }
}
