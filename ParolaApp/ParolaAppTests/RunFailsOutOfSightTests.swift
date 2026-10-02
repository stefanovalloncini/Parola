import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Run fails out of sight", .serialized, .timeLimit(.minutes(1)))
    struct RunFailsOutOfSightTests {
        private static let link = "https://youtu.be/dQw4w9WgXcQ"
        private static let unreachable = LinkDownloadFailure(reason: .unreachable, site: "YouTube")

        private func makeModel(fetcher: ScriptedLinkFetcher? = nil) -> AppModel {
            AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("run-fails"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock(),
                linkFetcher: fetcher
            ))
        }

        private static func failing(after gate: MockTranscriberGate? = nil) -> MockTranscriberResponse {
            MockTranscriberResponse(failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom"), gate: gate)
        }

        private static let words = MockTranscriberResponse(segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")])

        private static let captions = FetchedCaptions(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "the video's own captions")],
                language: "en", modelName: "youtube-subs"
            ),
            metadata: ScriptedLinkFetcher.talk
        )

        /// What the user opened while the run went on.
        private func openOlderEntry(in model: AppModel) async throws -> LibraryEntry.ID {
            let older = try await LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil).add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older entry")], language: "en", modelName: "stub"
                ),
                audioSource: nil
            )
            _ = try await model.openEntry(older.id)
            return older.id
        }

        private func expectLeftAlone(_ model: AppModel, older: LibraryEntry.ID, phases: PhaseRecorder) {
            #expect(model.route == .transcript)
            #expect(model.selectedEntryID == older, "the failure took the entry the user opened")
            #expect(model.transcript?.text == "an older entry")
            #expect(model.player == nil, "the run's audio went into the entry's player")
            let seen = phases.names
            #expect(seen == ["ready"], "the failure went over the entry")
            #expect(model.failedFileURL == nil && model.failedLink == nil, "the entry's page holds the run's Retry")
        }

        private func retry(_ model: AppModel) throws -> ExportNotice.Action {
            let actions = model.exportNotice?.actions ?? []
            #expect(actions.map(\.title) == ["Retry"])
            return try #require(actions.first)
        }

        @Test("a file run that fails after the user opened an entry leaves it up and says so with Retry, which runs the file again on its page")
        func fileFailureLeavesTheOpenedEntry() async throws {
            let wav = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.failing(after: gate))
                let model = makeModel()

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                let older = try await openOlderEntry(in: model)
                let phases = PhaseRecorder(model)
                await gate.open()

                let posted = await waitUntil { model.exportNotice != nil }
                #expect(posted, "the failure said nothing")
                expectLeftAlone(model, older: older, phases: phases)
                #expect(model.exportNotice?.message == "Couldn't transcribe \(wav.lastPathComponent). boom")
                #expect(model.exportNotice?.tone == .failure)
                #expect(model.exportNotice?.autoDismisses == false, "the failure goes before anyone reads it")
                let action = try retry(model)
                #expect(action.handler == .retryRun(.file(wav, translateOverride: nil)))

                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                await model.unloadTranscriptionSession()
                model.performNoticeAction(action)
                let landed = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                #expect(landed, "Retry never ran the file again")
                #expect(model.selectedEntryID != older)
                #expect(model.sourceFileURL == wav)
            }
        }

        @Test("a run failing out of sight goes over a notice that waits to be dismissed, which comes back after it")
        func failureKeepsTheNoticeItCovers() async throws {
            let wav = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.failing(after: gate))
                let model = makeModel()
                let saved = ExportNotice(
                    message: "Saved the previous recording without transcribing it.", failures: [], folder: nil, tone: .info,
                    actions: [
                        ExportNotice.Action(title: "Open", handler: .openEntry("older")),
                        ExportNotice.Action(title: "Transcribe", handler: .transcribeEntry("older")),
                    ]
                )

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                model.openStatistics()
                model.exportNotice = saved
                await gate.open()

                let posted = await waitUntil { model.exportNotice?.tone == .failure }
                #expect(posted, "the failure said nothing")
                model.dismissExportNotice()
                #expect(model.exportNotice?.id == saved.id, "the notice the failure went over never came back")
                model.dismissExportNotice()
                #expect(model.exportNotice == nil, "one deep, never a queue")
            }
        }

        @Test("a file gone by the time its run fails out of sight leaves the notice without Retry")
        func goneFileHasNoRetry() async throws {
            let wav = try makeLinkFixtureWAV()
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.failing(after: gate))
                let model = makeModel()

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                model.openStatistics()
                try FileManager.default.removeItem(at: wav)
                await gate.open()

                let posted = await waitUntil { model.exportNotice != nil }
                #expect(posted, "the failure said nothing")
                #expect(model.route == .statistics)
                #expect(model.phase == .idle)
                #expect(model.exportNotice?.message.hasPrefix("Couldn't transcribe \(wav.lastPathComponent). ") == true)
                #expect(model.exportNotice?.actions.isEmpty == true, "Retry would run a file that is gone")
            }
        }

        @Test("a file run cancelled after the user opened an entry says nothing")
        func cancelledRunStaysSilent() async throws {
            let wav = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.failing(after: gate))
                let model = makeModel()

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                let older = try await openOlderEntry(in: model)
                model.cancelCurrentWork()

                let settled = await model.awaitCancelSettled(within: .seconds(5))
                #expect(settled, "the cancelled run never unwound")
                #expect(model.exportNotice == nil, "a cancel is not a failure")
                #expect(model.selectedEntryID == older)
            }
        }

        @Test("a link whose download fails after the user opened an entry leaves it up and says so with Retry, which fetches the link again")
        func linkDownloadFailureLeavesTheOpenedEntry() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.transcriber) {
                let gate = FetchGate()
                defer { Task { await gate.open() } }
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate, failure: Self.unreachable))

                #expect(model.transcribeYouTube(urlString: Self.link) == .started)
                let older = try await openOlderEntry(in: model)
                let phases = PhaseRecorder(model)
                await gate.open()

                let posted = await waitUntil { model.exportNotice != nil }
                #expect(posted, "the failure said nothing")
                expectLeftAlone(model, older: older, phases: phases)
                let detail = AppModel.errorDetail(from: AppModel.transcriptionFailureMessage(for: ParolaError.linkDownloadFailed(Self.unreachable)))
                #expect(model.exportNotice?.message == "Couldn't transcribe \(Self.link). \(detail)")
                let action = try retry(model)
                #expect(action.handler == .retryRun(.link(.transcribe(Self.link))))

                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let again = ScriptedLinkFetcher(fixture: fixture)
                model.linkFetcher = again
                model.performNoticeAction(action)
                let landed = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                #expect(landed, "Retry never fetched the link again")
                #expect(again.fetches == 1)
            }
        }

        @Test("a link that fails to transcribe after the user opened an entry during its download names the video and retries the link")
        func linkTranscriptionFailureLeavesTheOpenedEntry() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.failing())
                let gate = FetchGate()
                defer { Task { await gate.open() } }
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))

                #expect(model.transcribeYouTube(urlString: Self.link) == .started)
                let older = try await openOlderEntry(in: model)
                let phases = PhaseRecorder(model)
                await gate.open()

                let posted = await waitUntil { model.exportNotice != nil }
                #expect(posted, "the failure said nothing")
                expectLeftAlone(model, older: older, phases: phases)
                #expect(model.exportNotice?.message == "Couldn't transcribe A talk. boom")
                let action = try retry(model)
                #expect(action.handler == .retryRun(.link(.transcribe(Self.link))))
            }
        }

        @Test("captions that fail after the user opened an entry leave it up and say so with Retry, which fetches the captions again")
        func captionsFailureLeavesTheOpenedEntry() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let gate = FetchGate()
            defer { Task { await gate.open() } }
            let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate, failure: Self.unreachable))

            #expect(model.fetchYouTubeSubs(urlString: Self.link) == .started)
            let older = try await openOlderEntry(in: model)
            let phases = PhaseRecorder(model)
            await gate.open()

            let posted = await waitUntil { model.exportNotice != nil }
            #expect(posted, "the failure said nothing")
            expectLeftAlone(model, older: older, phases: phases)
            let detail = AppModel.errorDetail(from: AppModel.transcriptionFailureMessage(for: ParolaError.linkDownloadFailed(Self.unreachable)))
            #expect(model.exportNotice?.message == "Couldn't transcribe \(Self.link). \(detail)")
            let action = try retry(model)
            #expect(action.handler == .retryRun(.link(.subtitles(Self.link))))

            model.linkFetcher = ScriptedLinkFetcher(fixture: fixture, captions: Self.captions)
            model.performNoticeAction(action)
            let landed = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own captions") == true }
            #expect(landed, "Retry never fetched the captions again")
        }

        @Test("captions a video doesn't have, failing out of sight, leave no Retry")
        func missingCaptionsHaveNoRetry() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let gate = FetchGate()
            defer { Task { await gate.open() } }
            let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))

            #expect(model.fetchYouTubeSubs(urlString: Self.link) == .started)
            model.openStatistics()
            await gate.open()

            let posted = await waitUntil { model.exportNotice != nil }
            #expect(posted, "the failure said nothing")
            #expect(model.route == .statistics)
            #expect(model.exportNotice?.message.hasPrefix("Couldn't transcribe \(Self.link). ") == true)
            #expect(model.exportNotice?.actions.isEmpty == true, "Retry can't find captions the video doesn't have")
        }
    }
}
