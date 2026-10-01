import Foundation
import Testing
import os
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Unsupported URL message")
struct YouTubeURLMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("an unsupported media URL surfaces the Italian message")
    func localizesUnsupportedURL() throws {
        let message = AppModel.unsupportedURLMessage(bundle: try italianBundle())
        #expect(message == "Questo URL non proviene da una sorgente supportata da yt-dlp.")
    }
}

/// Hands `finished` straight back, a download that completed just as it was cancelled; holds any other link until its task is cancelled.
private final class HeldLinkFetcher: LinkFetcher {
    private struct State {
        var held: CheckedContinuation<Void, any Error>?
        var isHolding = false
        var cancelled = false
    }

    private let finished: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(finished: URL) {
        self.finished = finished
    }

    var isHolding: Bool { state.withLock { $0.isHolding } }
    var heldFetchWasCancelled: Bool { state.withLock { $0.cancelled } }

    func fetchAudio(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        let media = FetchedMedia(fileURL: URL(fileURLWithPath: "/tmp/missing-\(UUID()).wav"))
        guard url != finished else { return media }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelledFirst = state.withLock { state -> Bool in
                    state.isHolding = true
                    guard !state.cancelled else { return true }
                    state.held = continuation
                    return false
                }
                if cancelledFirst { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let held = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.cancelled = true
                defer { state.held = nil }
                return state.held
            }
            held?.resume(throwing: CancellationError())
        }
        return media
    }

    func fetchCaptions(url: URL, language: String?) async throws -> FetchedCaptions {
        throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions))
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("YouTube task lifecycle")
    struct YouTubeTaskLifecycleTests {
        private func makeModel() -> AppModel {
            AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("yt"))
        }

        @Test("cancelled task leaves the replacement's handle intact")
        func restartKeepsHandle() async throws {
            let model = makeModel()
            let first = try #require(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa"))
            let fetcher = HeldLinkFetcher(finished: first)
            model.linkFetcher = fetcher
            model.transcribeYouTube(urlString: first.absoluteString)
            model.cancelCurrentWork()
            model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=bbbbbbbbbbb")

            await pollUntil("the cancelled link's task to unwind") { model.cancelSettled }
            await pollUntil("the second link's download to start") { fetcher.isHolding }
            #expect(model.canCancel)
            #expect(model.phase == .fetchingLink(title: nil, progress: nil))

            model.cancelCurrentWork()
            await pollUntil("Cancel to reach the second link's download") { fetcher.heldFetchWasCancelled }
            await pollUntil("the second link's task to unwind") { model.cancelSettled }
        }
    }
}
