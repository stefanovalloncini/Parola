import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

// .serialized: each test drives its own engine through a TestClock, and running six of them at once
// adds enough parked tasks to the pool to stall the rest of the run.
// .logFacade: every attempt writes a ParolaLog line, which would otherwise land in a sink another
// suite installed process-wide while it asserts on what it wrote.
@Suite("Delivery engine", .serialized, .tags(.fileSystem), .logFacade)
final class DeliveryEngineTests {
    private var tempDirectories: [URL] = []

    deinit {
        for url in tempDirectories { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Rig

    private func makeStore() throws -> DeliveryQueueStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return DeliveryQueueStore(directory: dir)
    }

    private func mock(
        name: String = "Mock vault",
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        failuresBeforeSuccess: Int = 0,
        recorder: MockDeliveryRecorder
    ) async -> MockDestination {
        let destination = MockDestination(
            name: name,
            isEnabled: isEnabled,
            autoSend: autoSend,
            categories: categories,
            recorder: recorder
        )
        await recorder.setFailures(failuresBeforeSuccess, for: destination.id)
        return destination
    }

    private func makeEngine(
        destinations: [AnyDestination],
        store: DeliveryQueueStore,
        clock: TestClock,
        payload: @escaping @Sendable (LibraryEntry.ID) async throws -> DeliveryPayload = { id in
            var payload = DeliveryPayloadTests.payload()
            payload.entryID = id
            return payload
        },
        receipts: ReceiptSpy? = nil
    ) -> DeliveryEngine {
        DeliveryEngine(
            destinations: { destinations },
            payload: payload,
            store: store,
            clock: clock,
            recordReceipt: { receipt, entryID in await receipts?.record(receipt, entryID) }
        )
    }

    private func poll(
        budget: Duration = .seconds(10),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Tests

    @Test("a delivery that works reports its receipt and records it against the entry")
    func deliveredReportsReceipt() async throws {
        let recorder = MockDeliveryRecorder()
        let receipts = ReceiptSpy()
        let destination = await mock(recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)], store: try makeStore(), clock: TestClock(), receipts: receipts
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        guard case .delivered(let receipt) = outcome else {
            Issue.record("expected a delivery, got \(outcome)")
            return
        }
        #expect(receipt.destinationName == "Mock vault")
        #expect(await receipts.entries == [receipt.destinationID: "entry-1"])
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
        #expect(await engine.pending().isEmpty)
    }

    @Test("a failure queues the delivery, arms its timer, and a retry clears it")
    func failureIsQueuedThenRetried() async throws {
        let recorder = MockDeliveryRecorder()
        let receipts = ReceiptSpy()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)], store: try makeStore(), clock: clock, receipts: receipts
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)
        guard case .queued(let attempt, let nextAt) = outcome else {
            Issue.record("expected the delivery to be queued, got \(outcome)")
            return
        }
        #expect(attempt == 1)
        #expect(nextAt.timeIntervalSinceNow > 30, "the first retry is a minute out")
        #expect(await engine.pending().count == 1)
        #expect(
            await poll { clock.sleeperCount == 1 },
            "the retry timer should be armed on the injected clock"
        )

        // The same entry point the toast's Retry runs through.
        let retried = await engine.send(entryID: "entry-1", to: destination.id)

        guard case .delivered(let receipt) = retried else {
            Issue.record("expected the retry to deliver, got \(retried)")
            return
        }
        #expect(receipt.destinationName == "Mock vault")
        #expect(await engine.pending().isEmpty, "the retry should have cleared the queue")
        #expect(await receipts.entries.values.contains("entry-1"))
        #expect(await recorder.recorded().count == 1)
        #expect(await poll { clock.sleeperCount == 0 }, "the armed timer should have been cancelled")
    }

    @Test("a delivery that never works is dropped after the last attempt")
    func givenUpAfterMaxAttempts() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 99, recorder: recorder)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)

        var outcome = await engine.send(entryID: "entry-1", to: destination.id)
        for attemptsSoFar in 1..<DeliveryEngine.maxAttempts {
            guard case .queued(let attempt, let nextAt) = outcome else {
                Issue.record("attempt \(attemptsSoFar) should have been queued, got \(outcome)")
                return
            }
            // A retry continues the backoff instead of starting it over.
            #expect(attempt == attemptsSoFar)
            let delay = DeliveryEngine.delay(forAttempt: attemptsSoFar)
            #expect(abs(nextAt.timeIntervalSinceNow - delay.wallSeconds) < 5)
            outcome = await engine.send(entryID: "entry-1", to: destination.id)
        }

        #expect(outcome == .skipped(reason: .givenUp("Mock vault")))
        #expect(await engine.pending().isEmpty, "the delivery should have been dropped")
        let log = await engine.recentLog()
        #expect(log.last?.event == .dropped)
        #expect(log.last?.attempt == DeliveryEngine.maxAttempts)
        #expect(log.filter { $0.event == .queued }.count == DeliveryEngine.maxAttempts - 1)
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("the clock brings a queued delivery back and it lands")
    func theClockRetriesAQueuedDelivery() async throws {
        let recorder = MockDeliveryRecorder()
        let receipts = ReceiptSpy()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)], store: try makeStore(), clock: clock, receipts: receipts
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)
        guard case .queued(let attempt, _) = outcome else {
            Issue.record("expected the delivery to be queued, got \(outcome)")
            return
        }
        #expect(attempt == 1)
        #expect(await poll { clock.sleeperCount == 1 }, "the retry timer should be armed")

        // Taken before the clock moves, awaited after: the retry is a suspension point here,
        // never a wait on real time.
        let timer = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await timer?.value

        #expect(await engine.pending().isEmpty, "the retry should have cleared the queue")
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
        #expect(await receipts.entries.values.contains("entry-1"))
        #expect(await engine.recentLog().last?.event == .delivered)
    }

    @Test("a retry that fails again moves to the next backoff step")
    func aSecondFailureMovesToTheNextStep() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 99, recorder: recorder)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)

        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await poll { clock.sleeperCount == 1 })
        let timer = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await timer?.value

        let queued = try #require(await engine.pending().first)
        #expect(queued.attempt == 2)
        #expect(
            abs(queued.nextAttemptAt.timeIntervalSinceNow - DeliveryEngine.delay(forAttempt: 2).wallSeconds) < 5,
            "the second attempt waits out the second step"
        )
        #expect(await engine.recentLog().filter { $0.event == .queued }.count == 2)
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("a queue with a future attempt waits out what is left of it, not zero")
    func aFutureAttemptKeepsItsRemainingDelay() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let store = try makeStore()
        let destination = await mock(recorder: recorder)
        store.save(queue: [
            QueuedDelivery(
                entryID: "entry-1",
                destinationID: destination.id,
                attempt: 2,
                nextAttemptAt: Date().addingTimeInterval(600)
            )
        ])

        let engine = makeEngine(destinations: [.mock(destination)], store: store, clock: clock)

        #expect(await poll { clock.sleeperCount == 1 }, "the stored delivery should have armed a timer")
        clock.advance(by: .seconds(60))
        #expect(clock.sleeperCount == 1, "a minute in, the timer is still waiting out the rest")
        #expect(await recorder.recorded().isEmpty)

        let timer = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: .seconds(600))
        await timer?.value

        #expect(await engine.pending().isEmpty)
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
    }

    @Test("auto-send only runs the destinations that asked for it")
    func autoSendFansOut() async throws {
        let recorder = MockDeliveryRecorder()
        let auto = await mock(name: "Auto", autoSend: true, recorder: recorder)
        let manual = await mock(name: "Manual", autoSend: false, recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(auto), .mock(manual)], store: try makeStore(), clock: TestClock()
        )

        let attempts = await engine.sendAutomatically(entryID: "entry-1")

        #expect(attempts.map(\.destinationName) == ["Auto"])
        let names = await recorder.receipts().map(\.destinationName)
        #expect(names == ["Auto"])
    }

    @Test("auto-send skips a destination that does not take this category")
    func categoryFilter() async throws {
        let recorder = MockDeliveryRecorder()
        let meetings = await mock(name: "Meetings", autoSend: true, categories: [.meeting], recorder: recorder)
        let dictations = await mock(name: "Dictations", autoSend: true, categories: [.dictation], recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(meetings), .mock(dictations)],
            store: try makeStore(),
            clock: TestClock()
        )

        let attempts = await engine.sendAutomatically(entryID: "entry-1")

        #expect(attempts.map(\.destinationName) == ["Meetings"])
        #expect(await recorder.receipts().map(\.destinationName) == ["Meetings"])
    }

    @Test("a destination that is switched off is skipped, not queued")
    func disabledIsSkipped() async throws {
        let recorder = MockDeliveryRecorder()
        let destination = await mock(isEnabled: false, recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)], store: try makeStore(), clock: TestClock()
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(outcome == .skipped(reason: .notEnabled))
        #expect(await engine.pending().isEmpty)
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("a destination the list does not hold is skipped")
    func unknownDestination() async throws {
        let engine = makeEngine(destinations: [], store: try makeStore(), clock: TestClock())
        let outcome = await engine.send(entryID: "entry-1", to: UUID())
        #expect(outcome == .skipped(reason: .unknownDestination))
    }

    @Test("a kind this build cannot run is skipped rather than attempted")
    func unsupportedKindIsSkipped() async throws {
        let stored = AnyDestination.unsupported(
            kind: "notion",
            config: .object(["id": .string("6C9C1E1E-0000-0000-0000-00000000000A")])
        )
        let engine = makeEngine(destinations: [stored], store: try makeStore(), clock: TestClock())

        let outcome = await engine.send(entryID: "entry-1", to: stored.id)

        #expect(outcome == .skipped(reason: .unsupportedKind("notion")))
    }

    @Test("a payload the library cannot build is skipped with the reason")
    func payloadFailureIsSkipped() async throws {
        let recorder = MockDeliveryRecorder()
        let destination = await mock(recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)],
            store: try makeStore(),
            clock: TestClock(),
            payload: { _ in throw LibraryStore.LibraryError.notFound("entry-1") }
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        guard case .skipped(.payloadUnavailable) = outcome else {
            Issue.record("expected a payload failure, got \(outcome)")
            return
        }
        #expect(await engine.pending().isEmpty)
    }

    @Test("a transcript the retry cannot read is queued again, not dropped")
    func payloadFailureOnRetryStaysQueued() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let payloads = PayloadSpy(failingCall: 2)
        let engine = makeEngine(
            destinations: [.mock(destination)],
            store: try makeStore(),
            clock: clock,
            payload: { try await payloads.build($0) }
        )

        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await poll { clock.sleeperCount == 1 })
        let first = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await first?.value

        let queued = try #require(await engine.pending().first, "a transcript that cannot be read stays queued")
        #expect(queued.attempt == 2)
        #expect(await engine.recentLog().last?.event == .queued)

        #expect(await poll { clock.sleeperCount == 1 })
        let second = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 2))
        await second?.value

        #expect(await engine.pending().isEmpty)
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
        #expect(await engine.recentLog().last?.event == .delivered)
    }

    @Test("a transcript deleted before the retry is dropped, not sent")
    func deletedEntryIsDroppedOnRetry() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let payloads = PayloadSpy(failingCall: 2, error: DeliveryPayloadError.entryGone("entry-1"))
        let engine = makeEngine(
            destinations: [.mock(destination)],
            store: try makeStore(),
            clock: clock,
            payload: { try await payloads.build($0) }
        )

        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await poll { clock.sleeperCount == 1 })
        let retry = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await retry?.value

        #expect(await engine.pending().isEmpty)
        #expect(await recorder.recorded().isEmpty)
        let last = try #require(await engine.recentLog().last)
        #expect(last.event == .dropped)
        #expect(last.destinationID == destination.id)
    }

    @Test("cancelling an entry drops its queued deliveries before they run")
    func cancelDropsTheQueue() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)
        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await engine.pending().count == 1)

        await engine.cancel(entryID: "entry-1")

        #expect(await engine.pending().isEmpty)
        #expect(await engine.timerTask(for: "entry-1", destinationID: destination.id) == nil)
        let last = try #require(await engine.recentLog().last)
        #expect(last.event == .dropped)
        #expect(last.destinationName == "Mock vault")
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("a retry that drops the entry while cancel waits for the destination names is logged once")
    func cancelRacingARetryLogsOneDrop() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let gate = DestinationsGate([.mock(destination)])
        let payloads = PayloadSpy(failingCall: 2, error: DeliveryPayloadError.entryGone("entry-1"))
        let engine = DeliveryEngine(
            destinations: { await gate.list() },
            payload: { try await payloads.build($0) },
            store: try makeStore(),
            clock: clock
        )
        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await poll { clock.sleeperCount == 1 })
        let retry = await engine.timerTask(for: "entry-1", destinationID: destination.id)

        await gate.arm()
        let cancelling = Task { await engine.cancel(entryID: "entry-1") }
        #expect(await poll { await gate.isHolding })
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await retry?.value
        await gate.release()
        await cancelling.value

        #expect(await engine.pending().isEmpty)
        #expect(await engine.recentLog().filter { $0.event == .dropped }.count == 1)
    }

    @Test("an auto-send whose transcript can't be read logs each destination it would have used")
    func autoSendPayloadFailureNamesTheDestinations() async throws {
        let recorder = MockDeliveryRecorder()
        let destination = await mock(autoSend: true, recorder: recorder)
        let engine = makeEngine(
            destinations: [.mock(destination)],
            store: try makeStore(),
            clock: TestClock(),
            payload: { throw DeliveryPayloadError.entryGone($0) }
        )

        let attempts = await engine.sendAutomatically(entryID: "entry-1")

        #expect(attempts.isEmpty)
        let last = try #require(await engine.recentLog().last)
        #expect(last.destinationID == destination.id)
        #expect(last.destinationName == "Mock vault")
    }

    @Test("a second send for the same destination while one is in flight is skipped")
    func oneKeyIsSentOnceAtATime() async throws {
        let recorder = MockDeliveryRecorder()
        let destination = await mock(recorder: recorder)
        let engines = EngineBox()
        let reentrant = OutcomeBox()
        let engine = DeliveryEngine(
            destinations: { [.mock(destination)] },
            payload: { id in
                var payload = DeliveryPayloadTests.payload()
                payload.entryID = id
                return payload
            },
            store: try makeStore(),
            clock: TestClock(),
            // Re-entering here is what two simultaneous sends look like from inside the engine:
            // the first attempt is suspended and still holds the key.
            recordReceipt: { _, entryID in
                guard let engine = await engines.engine else { return }
                await reentrant.record(await engine.send(entryID: entryID, to: destination.id))
            }
        )
        await engines.set(engine)

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(outcome.isDelivered)
        #expect(await reentrant.outcomes == [.skipped(reason: .alreadySending("Mock vault"))])
        #expect(await recorder.recorded().count == 1, "the second send must not write a second note")
        #expect(await engine.pending().isEmpty)
    }

    @Test("a queue written by an earlier run is picked up by the next one")
    func queueSurvivesReInit() async throws {
        let recorder = MockDeliveryRecorder()
        let store = try makeStore()
        let destination = await mock(recorder: recorder)
        let queued = QueuedDelivery(
            entryID: "entry-1",
            destinationID: destination.id,
            attempt: 1,
            nextAttemptAt: Date(timeIntervalSince1970: 0)
        )
        store.save(queue: [queued])
        #expect(store.loadQueue() == [queued])

        let engine = makeEngine(destinations: [.mock(destination)], store: store, clock: TestClock())

        #expect(await poll { await engine.pending().isEmpty }, "the stored delivery should have run")
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
        #expect(store.loadQueue().isEmpty)
    }

    // MARK: - Reachability

    private func queued(_ entryID: LibraryEntry.ID, to destination: MockDestination, attempt: Int = 1, dueIn: TimeInterval) -> QueuedDelivery {
        QueuedDelivery(
            entryID: entryID, destinationID: destination.id, attempt: attempt,
            nextAttemptAt: Date().addingTimeInterval(dueIn)
        )
    }

    @Test("a retry to an unreachable destination doesn't read the transcript")
    func unreachableSkipsThePayload() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(recorder: recorder)
        await recorder.setReachable(false, for: destination.id)
        let payloads = PayloadSpy(failingCall: 0)
        let engine = makeEngine(
            destinations: [.mock(destination)], store: try makeStore(), clock: clock,
            payload: { try await payloads.build($0) }
        )

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)
        guard case .queued(0, _) = outcome else {
            Issue.record("expected the send to wait for its destination, got \(outcome)")
            return
        }
        #expect(await poll { clock.sleeperCount == 1 })
        let timer = await engine.timerTask(for: "entry-1", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await timer?.value

        #expect(await payloads.calls == 0)
        let waiting = try #require(await engine.pending().first)
        #expect(waiting.attempt == 0, "a destination out of reach counts no attempt")
        #expect(waiting.unreachableChecks == 2)
        #expect(abs(waiting.nextAttemptAt.timeIntervalSinceNow - DeliveryEngine.delay(forAttempt: 2).wallSeconds) < 5)
    }

    @Test("a destination out of reach for every check is given up on at the last one")
    func unreachableIsGivenUpOnEventually() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let store = try makeStore()
        let destination = await mock(recorder: recorder)
        await recorder.setReachable(false, for: destination.id)
        store.save(queue: [
            QueuedDelivery(
                entryID: "entry-1", destinationID: destination.id, attempt: 2,
                nextAttemptAt: Date().addingTimeInterval(-1), unreachableChecks: DeliveryEngine.maxUnreachableChecks
            )
        ])
        let engine = makeEngine(destinations: [.mock(destination)], store: store, clock: clock)

        #expect(await poll { await engine.pending().isEmpty })
        #expect(await engine.recentLog().last?.event == .dropped)
    }

    @Test("a queue written before the reachability count reads as not waiting")
    func olderQueueDecodes() throws {
        let json = #"[{"entryID":"e","destinationID":"6C9C1E1E-0000-0000-0000-00000000000A","attempt":3,"nextAttemptAt":"2026-09-01T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let queue = try decoder.decode([QueuedDelivery].self, from: Data(json.utf8))
        #expect(queue.first?.attempt == 3)
        #expect(queue.first?.isWaitingForDestination == false)
    }

    @Test("one failed check reschedules every delivery to that destination that was due, and nothing else")
    func oneFailedCheckDefersTheGroup() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let store = try makeStore()
        let vault = await mock(name: "Vault", recorder: recorder)
        let other = await mock(name: "Other", recorder: recorder)
        await recorder.setReachable(false, for: vault.id)
        store.save(queue: [
            queued("entry-1", to: vault, dueIn: -600),
            queued("entry-2", to: vault, dueIn: -300),
            queued("entry-3", to: vault, dueIn: 3600),
            queued("entry-4", to: other, dueIn: 3600),
        ])
        let payloads = PayloadSpy(failingCall: 0)
        let engine = makeEngine(
            destinations: [.mock(vault), .mock(other)], store: store, clock: clock,
            payload: { try await payloads.build($0) }
        )

        #expect(await poll { await engine.pending().first { $0.entryID == "entry-1" }?.unreachableChecks == 1 })

        let pending = await engine.pending()
        #expect(pending.first { $0.entryID == "entry-2" }?.unreachableChecks == 1, "the other due delivery moved with it")
        #expect(pending.allSatisfy { $0.attempt == 1 }, "being out of reach counts no attempt")
        #expect(pending.first { $0.entryID == "entry-3" }?.unreachableChecks == 0, "a delivery not yet due keeps its turn")
        #expect(pending.first { $0.entryID == "entry-4" }?.unreachableChecks == 0, "another destination is left alone")
        #expect(await recorder.reachabilityChecks() == 1)
        #expect(await payloads.calls == 0)
    }

    @Test("deliveries that fell due while Parola was quit go out one at a time")
    func launchResumeIsSpacedOut() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let store = try makeStore()
        let destination = await mock(recorder: recorder)
        store.save(queue: (1...3).map { queued("entry-\($0)", to: destination, dueIn: -60) })

        let engine = makeEngine(destinations: [.mock(destination)], store: store, clock: clock)

        #expect(await poll { await recorder.recorded().count == 1 })
        #expect(await poll { clock.sleeperCount == 2 }, "the other two wait their turn")
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])

        let second = await engine.timerTask(for: "entry-2", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.catchUpSpacing)
        await second?.value
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1", "entry-2"])

        #expect(await poll { clock.sleeperCount == 1 })
        let third = await engine.timerTask(for: "entry-3", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.catchUpSpacing)
        await third?.value
        #expect(await engine.pending().isEmpty)
    }

    @Test("the launch resume leaves a delivery a send already armed on its own timer")
    func resumeKeepsAnArmedTimer() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(failuresBeforeSuccess: 1, recorder: recorder)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)
        _ = await engine.send(entryID: "entry-1", to: destination.id)
        #expect(await poll { clock.sleeperCount == 1 })
        let armed = await engine.timerTask(for: "entry-1", destinationID: destination.id)

        await engine.resumeQueue()

        #expect(await engine.timerTask(for: "entry-1", destinationID: destination.id) == armed)
        clock.advance(by: DeliveryEngine.delay(forAttempt: 1))
        await armed?.value
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1"])
    }

    @Test("retrying a fixed destination sends what it queued now, not on the old schedule")
    func retryNowSendsAFixedDestination() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(recorder: recorder)
        await recorder.setReachable(false, for: destination.id)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)
        _ = await engine.send(entryID: "entry-1", to: destination.id)
        _ = await engine.send(entryID: "entry-2", to: destination.id)
        #expect(await engine.pending().count == 2)

        await recorder.setReachable(true, for: destination.id)
        await engine.retryNow(destinationID: destination.id)

        #expect(await poll { await recorder.recorded().count == 1 })
        #expect(await poll { clock.sleeperCount == 1 }, "the second waits its turn")
        let second = await engine.timerTask(for: "entry-2", destinationID: destination.id)
        clock.advance(by: DeliveryEngine.catchUpSpacing)
        await second?.value
        #expect(await recorder.recorded().map(\.entryID) == ["entry-1", "entry-2"])
        #expect(await engine.pending().isEmpty)
    }

    @Test("a mount or an edit brings forward only deliveries that were waiting for the destination")
    func retryNowSkipsOtherFailures() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let store = try makeStore()
        let destination = await mock(recorder: recorder)
        store.save(queue: [
            queued("write-failed", to: destination, attempt: 1, dueIn: 3600),
            QueuedDelivery(
                entryID: "was-away", destinationID: destination.id, attempt: 0,
                nextAttemptAt: Date().addingTimeInterval(3600), unreachableChecks: 1
            ),
        ])
        let engine = makeEngine(destinations: [.mock(destination)], store: store, clock: clock)
        #expect(await poll { clock.sleeperCount == 2 })

        await engine.retryNow(destinationID: destination.id)

        #expect(await poll { await recorder.recorded().count == 1 })
        #expect(await recorder.recorded().map(\.entryID) == ["was-away"])
        let left = try #require(await engine.pending().first)
        #expect(left.entryID == "write-failed")
        #expect(left.attempt == 1, "an ordinary failure keeps its backoff and its count")
    }

    @Test("retrying a destination that is still unreachable changes nothing and counts no attempt")
    func retryNowLeavesAnUnreachableDestination() async throws {
        let recorder = MockDeliveryRecorder()
        let clock = TestClock()
        let destination = await mock(recorder: recorder)
        await recorder.setReachable(false, for: destination.id)
        let engine = makeEngine(destinations: [.mock(destination)], store: try makeStore(), clock: clock)
        _ = await engine.send(entryID: "entry-1", to: destination.id)
        let before = try #require(await engine.pending().first)

        await engine.retryNow()

        let after = try #require(await engine.pending().first)
        #expect(after == before)
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("an Obsidian vault that isn't there fails its check; one that is passes")
    func obsidianReachability() async throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-reach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        tempDirectories.append(vault)
        let bookmark = try vault.bookmarkData()
        let destination = ObsidianVaultFolderDestination(
            name: "Vault", vaultBookmark: bookmark, vaultPath: vault.path
        )

        try await destination.checkReachable()

        try FileManager.default.removeItem(at: vault)
        await #expect(throws: DeliveryError.self) { try await destination.checkReachable() }
        let unset = ObsidianVaultFolderDestination(name: "Unset", vaultBookmark: Data(), vaultPath: "")
        await #expect(throws: DeliveryError.self) { try await unset.checkReachable() }
    }

    @Test("the reachability check resolves the vault without mounting a volume or showing UI")
    func reachabilityNeverMounts() throws {
        let options = ObsidianVaultFolderDestination.reachabilityResolution
        #expect(options.contains(.withoutMounting))
        #expect(options.contains(.withoutUI))
    }

    @Test("the backoff steps are one minute, five, thirty, then daily")
    func backoffSchedule() {
        #expect(DeliveryEngine.delay(forAttempt: 1) == .seconds(60))
        #expect(DeliveryEngine.delay(forAttempt: 2) == .seconds(300))
        #expect(DeliveryEngine.delay(forAttempt: 3) == .seconds(1800))
        #expect(DeliveryEngine.delay(forAttempt: 4) == .seconds(86_400))
        #expect(DeliveryEngine.delay(forAttempt: 9) == .seconds(86_400))
        #expect(DeliveryEngine.maxAttempts == 10)
    }
}

@Suite("Delivery log")
struct DeliveryLogTests {
    private func entry(_ index: Int) -> DeliveryLogEntry {
        DeliveryLogEntry(
            at: Date(timeIntervalSince1970: Double(index)),
            event: .delivered,
            entryID: "entry-\(index)",
            destinationID: UUID(),
            destinationName: "Vault",
            attempt: 1,
            detail: nil
        )
    }

    @Test("the ring keeps the last hundred lines")
    func ringCaps() {
        var log = DeliveryLog()
        for index in 0..<150 { log.append(entry(index)) }
        #expect(log.entries.count == DeliveryLog.capacity)
        #expect(log.entries.first?.entryID == "entry-50")
        #expect(log.entries.last?.entryID == "entry-149")
    }

    @Test("a log round-trips through its file")
    func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeliveryQueueStore(directory: dir)

        var log = DeliveryLog()
        log.append(entry(1))
        store.save(log: log)

        #expect(store.loadLog().entries == log.entries)
        #expect(FileManager.default.fileExists(atPath: store.logURL.path))
    }

    @Test("a queue and a log that will not decode read as empty, and say so in the log")
    func corruptFilesReadAsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeliveryQueueStore(directory: dir)
        try Data("{ not json".utf8).write(to: store.queueURL)
        try Data("{ not json".utf8).write(to: store.logURL)

        let sink = CapturingDiagnosticsSink()
        ParolaLog.withSink(sink) {
            #expect(store.loadQueue().isEmpty)
            #expect(store.loadLog().entries.isEmpty)
        }

        #expect(sink.records.filter { $0.level == .error }.count == 2)
    }

    @Test("a queue that cannot be written is logged rather than lost in silence")
    func unwritableQueueIsLogged() throws {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let store = DeliveryQueueStore(directory: blocked)

        let sink = CapturingDiagnosticsSink()
        ParolaLog.withSink(sink) {
            store.save(queue: [
                QueuedDelivery(entryID: "entry-1", destinationID: UUID(), attempt: 1, nextAttemptAt: Date())
            ])
        }

        #expect(sink.records.contains { $0.level == .error })
        #expect(store.loadQueue().isEmpty)
    }

    @Test("an absent file reads as an empty queue and log")
    func absentFiles() {
        let store = DeliveryQueueStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-delivery-missing-\(UUID().uuidString)", isDirectory: true)
        )
        #expect(store.loadQueue().isEmpty)
        #expect(store.loadLog().entries.isEmpty)
    }
}

/// Hands the engine to a callback the engine itself was built with.
actor EngineBox {
    private(set) var engine: DeliveryEngine?

    func set(_ engine: DeliveryEngine) {
        self.engine = engine
    }
}

/// Collects the outcomes of sends made from inside another send.
actor OutcomeBox {
    private(set) var outcomes: [DeliveryOutcome] = []

    func record(_ outcome: DeliveryOutcome) {
        outcomes.append(outcome)
    }
}

/// Builds the payload the engine sends, and throws on one chosen call so a retry can be made to
/// fail on reading the transcript rather than on the destination.
actor PayloadSpy {
    private(set) var calls = 0
    private let failingCall: Int
    private let error: any Error

    init(failingCall: Int, error: any Error = CocoaError(.fileReadUnknown)) {
        self.failingCall = failingCall
        self.error = error
    }

    func build(_ entryID: LibraryEntry.ID) throws -> DeliveryPayload {
        calls += 1
        guard calls != failingCall else { throw error }
        var payload = DeliveryPayloadTests.payload()
        payload.entryID = entryID
        return payload
    }
}

/// Holds the first destinations fetch after `arm()` until `release()`, so a test can run a retry inside it.
actor DestinationsGate {
    private let destinations: [AnyDestination]
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    init(_ destinations: [AnyDestination]) {
        self.destinations = destinations
    }

    func arm() {
        armed = true
    }

    func list() async -> [AnyDestination] {
        if armed {
            armed = false
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        return destinations
    }

    func release() {
        isHolding = false
        held?.resume()
        held = nil
    }
}

/// Records what the engine hands back for the manifest.
actor ReceiptSpy {
    private(set) var entries: [UUID: LibraryEntry.ID] = [:]

    func record(_ receipt: DeliveryReceipt, _ entryID: LibraryEntry.ID) {
        entries[receipt.destinationID] = entryID
    }
}
