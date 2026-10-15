import Foundation
import Testing
import os
@testable import ParolaCore

private final class FakeRequest: AssetInstalling {
    private let fraction = OSAllocatedUnfairLock(initialState: 0.0)
    private let outcome = FirstResult<Result<Void, any Error>>()
    let cancelled = TestSignal()

    var fractionCompleted: Double { fraction.withLock { $0 } }

    func move(to value: Double) { fraction.withLock { $0 = value } }
    func finish() { outcome.resolve(.success(())) }
    func fail(_ error: any Error) { outcome.resolve(.failure(error)) }

    func downloadAndInstall() async throws {
        try await outcome.wait().get()
    }

    func cancel() {
        cancelled.fire()
        outcome.resolve(.failure(CancellationError()))
    }
}

private struct Offline: Error {}

@Suite("Apple Speech asset install", .timeLimit(.minutes(1)))
struct AssetInstallTests {
    private static let locale = Locale(identifier: "it_IT")
    private static let poll = Duration.seconds(1)

    private func install(
        _ request: FakeRequest, clock: TestClock, progress: Awaitable<[Double]> = Awaitable([])
    ) -> GuardedTask<Void> {
        GuardedTask {
            try await AssetInstall.run(
                request, locale: Self.locale, stallLimit: .seconds(60), poll: Self.poll, clock: clock
            ) { fraction in progress.update { $0.append(fraction) } }
        }
    }

    private func tick(_ clock: TestClock, times: Int) async {
        for _ in 0..<times {
            await clock.waitForSleeper()
            clock.advance(by: Self.poll)
        }
    }

    private func failureText(_ task: GuardedTask<Void>) async -> String {
        do {
            _ = try await task.value("the install to end")
            return "no failure"
        } catch let ParolaError.unsupportedForEngine(text) {
            return text
        } catch {
            return "other: \(error)"
        }
    }

    @Test("progress is reported while the install runs and the install returns when it finishes")
    func reportsProgress() async throws {
        let request = FakeRequest()
        let clock = TestClock()
        let seen = Awaitable<[Double]>([])
        let task = install(request, clock: clock, progress: seen)
        request.move(to: 0.4)
        await tick(clock, times: 1)
        await seen.wait(until: { $0.contains(0.4) }, "the moved fraction")
        request.finish()
        _ = try await task.value("the install to return")
    }

    @Test("a cancelled install cancels the request and throws a cancellation")
    func cancellationReachesTheRequest() async throws {
        let request = FakeRequest()
        let clock = TestClock()
        let task = install(request, clock: clock)
        await clock.waitForSleeper()
        task.cancel()
        await request.cancelled.wait("the request to be cancelled")
        await #expect(throws: CancellationError.self) { _ = try await task.value("the install to end") }
    }

    @Test("progress that stops moving for the limit fails the install with the download sentence")
    func stalledDownload() async {
        let request = FakeRequest()
        let clock = TestClock()
        let task = install(request, clock: clock)
        request.move(to: 0.2)
        await tick(clock, times: 60)
        let text = await failureText(task)
        #expect(text == FixedFailureText.appleSpeechDownloadFailed(LiveSpeechCaption.languageName(Self.locale)))
        #expect(request.cancelled.fired)
    }

    @Test("progress that keeps moving never counts as a stall")
    func movingProgressIsNotAStall() async throws {
        let request = FakeRequest()
        let clock = TestClock()
        let task = install(request, clock: clock)
        for step in 1...100 {
            request.move(to: Double(step) / 200)
            await clock.waitForSleeper()
            clock.advance(by: Self.poll)
        }
        #expect(!task.isFinished)
        #expect(!request.cancelled.fired)
        request.finish()
        _ = try await task.value("the install to return")
    }

    @Test("a download that throws reads as a connection problem")
    func downloadError() async {
        let request = FakeRequest()
        let clock = TestClock()
        let task = install(request, clock: clock)
        await clock.waitForSleeper()
        request.fail(Offline())
        let text = await failureText(task)
        #expect(text == FixedFailureText.appleSpeechDownloadFailed(LiveSpeechCaption.languageName(Self.locale)))
    }
}
