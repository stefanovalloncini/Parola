import Foundation

protocol AssetInstalling: Sendable {
    var fractionCompleted: Double { get }
    func downloadAndInstall() async throws
    func cancel()
}

enum AssetInstall {
    /// Past this the download is done and Speech is unpacking, which reports no progress of its own.
    private static let installingFraction = 0.99

    private struct Stalled: Error {}

    /// Runs the install, reporting progress. A stop cancels the request, and so does progress that stays put for `stallLimit`.
    static func run(
        _ request: any AssetInstalling,
        locale: Locale,
        stallLimit: Duration = .seconds(60),
        poll: Duration = .milliseconds(250),
        clock: any Clock<Duration> = ContinuousClock(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let race = FirstResult<Result<Void, any Error>>()
        let download = Task {
            do {
                try await request.downloadAndInstall()
                race.resolve(.success(()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let watcher = Task {
            var last = request.fractionCompleted
            var still = Duration.zero
            progress(last)
            while !Task.isCancelled {
                guard (try? await clock.sleep(for: poll)) != nil else { return }
                let now = request.fractionCompleted
                if now != last {
                    last = now
                    still = .zero
                    progress(now)
                } else if now < installingFraction {
                    still += poll
                    if still >= stallLimit {
                        race.resolve(.failure(Stalled()))
                        return
                    }
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            request.cancel()
            race.resolve(.failure(CancellationError()))
        }
        watcher.cancel()
        switch outcome {
        case .success:
            return
        case .failure(let error):
            if error is CancellationError { throw error }
            download.cancel()
            request.cancel()
            ParolaLog.error(.engineAppleSpeech, "captions asset install failed", [.error: .error(error)])
            throw LiveSpeechCaption.downloadFailed(for: locale)
        }
    }
}
