import Foundation
import os
import Testing
@testable import ParolaCore

private actor FakeTap: TargetsGoneReporting {
    var watched: [UInt32]
    private(set) var rewatched: [[UInt32]] = []

    init(watched: [UInt32]) { self.watched = watched }

    func watchedProcessObjects() async -> [UInt32] { watched }
    func rewatchTargets(_ survivors: [UInt32], _ handler: @escaping @Sendable () -> Void) async {
        rewatched.append(survivors)
        watched = survivors
    }
    func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async {}
    func whenCaptureEnds(_ handler: @escaping @Sendable () -> Void) async {}
    func start() async throws {}
    func prepare() async throws -> URL { throw CancellationError() }
    func cancel() async {}
}

private func probe(_ objects: [UInt32], outputting: Set<UInt32> = []) -> TapEnd.Probe {
    TapEnd.Probe(objects: { objects }, isRunningOutput: { outputting.contains($0) })
}

@Suite("TapEnd")
struct TapEndTests {
    @Test("a bundle with no objects left is a quit")
    func quit() {
        #expect(TapEnd.verdict(watched: [1, 2], probe: probe([])) == .ended(.quit))
    }

    @Test("a camera helper leaving while the main process still plays keeps the capture going")
    func helperLeavesMainPlays() {
        #expect(TapEnd.verdict(watched: [1, 2], probe: probe([1], outputting: [1])) == .alive(survivors: [1]))
    }

    @Test("an audio helper that respawns as a new object reads as stopped sending")
    func respawn() {
        #expect(TapEnd.verdict(watched: [1, 2], probe: probe([1, 3])) == .ended(.stoppedSending))
        #expect(TapEnd.verdict(watched: [2], probe: probe([5])) == .ended(.stoppedSending))
    }

    @Test("quiet survivors with nothing new are not an end")
    func quietSurvivors() {
        #expect(TapEnd.verdict(watched: [1, 2], probe: probe([1])) == .alive(survivors: [1]))
    }

    @Test("a playing survivor outranks a new object")
    func playingSurvivorWins() {
        #expect(TapEnd.verdict(watched: [1, 2], probe: probe([1, 3], outputting: [1])) == .alive(survivors: [1]))
    }

    @Test("the re-query runs after the settle, so a family that finishes leaving inside it reads as quit", .timeLimit(.minutes(1)))
    func requeryAfterSettle() async {
        let clock = TestClock()
        let objects = OSAllocatedUnfairLock<[UInt32]>(initialState: [1])
        let probe = TapEnd.Probe(objects: { objects.withLock { $0 } }, isRunningOutput: { _ in false })
        let task = Task { await TapEnd.settled(after: .seconds(1), on: clock, watched: [1, 2], probe: probe) }
        await clock.waitForSleeper()
        objects.withLock { $0 = [] }
        clock.advance(by: .seconds(1))
        #expect(await task.value == .ended(.quit))
    }

    @Test("a helper back inside the settle reads as stopped sending", .timeLimit(.minutes(1)))
    func respawnInsideSettle() async {
        let clock = TestClock()
        let objects = OSAllocatedUnfairLock<[UInt32]>(initialState: [])
        let probe = TapEnd.Probe(objects: { objects.withLock { $0 } }, isRunningOutput: { _ in false })
        let task = Task { await TapEnd.settled(after: .seconds(1), on: clock, watched: [2], probe: probe) }
        await clock.waitForSleeper()
        objects.withLock { $0 = [5] }
        clock.advance(by: .seconds(1))
        #expect(await task.value == .ended(.stoppedSending))
    }

    @Test("a cancel during the settle gives nil", .timeLimit(.minutes(1)))
    func cancelled() async {
        let clock = TestClock()
        let task = Task { await TapEnd.settled(after: .seconds(1), on: clock, watched: [1], probe: probe([1])) }
        await clock.waitForSleeper()
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("resolve watches a living tap's survivors again and reports no end", .timeLimit(.minutes(1)))
    func resolveRearms() async {
        let clock = TestClock()
        let tap = FakeTap(watched: [1, 2])
        let task = Task {
            await TapEnd.resolve(tap, after: .seconds(1), on: clock, probe: probe([1], outputting: [1]), rearm: {})
        }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await task.value == nil)
        #expect(await tap.rewatched == [[1]])
    }

    @Test("resolve returns a real end without watching again", .timeLimit(.minutes(1)))
    func resolveEnds() async {
        let clock = TestClock()
        let tap = FakeTap(watched: [1, 2])
        let task = Task { await TapEnd.resolve(tap, after: .seconds(1), on: clock, probe: probe([]), rearm: {}) }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await task.value == .quit)
        #expect(await tap.rewatched.isEmpty)
    }
}
