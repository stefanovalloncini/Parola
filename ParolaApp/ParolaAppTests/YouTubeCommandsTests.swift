import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Bridge YouTube commands")
    struct YouTubeCommandsTests {

        private func makeRig(
            features: Set<ParolaFeature> = Set(ParolaFeature.allCases)
        ) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("youtubecommands"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: SystemFilePicker(),
                enabledFeaturesOverride: features
            )
            let model = AppModel(bootstrap: bootstrap)
            let server = try ParolaAutomationServer(model: model)
            let context = AutomationContext(model: model, server: server)
            let pairs = (server.transcriptCommands() + server.windowCommands()).map { ($0.name, $0) }
            return (model, server, context, Dictionary(uniqueKeysWithValues: pairs))
        }

        private static let link = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        @Test("transcribeYouTube owns up to parking a link handed over during a take")
        func transcribeYouTubeReportsParked() async throws {
            let (model, server, context, commands) = try makeRig()
            model.installTestTake(source: .microphone)
            let command = try #require(commands["transcribeYouTube"])
            let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

            let result = try await command.handler(args, context)
            withExtendedLifetime(server) {}

            #expect(result == .object(["started": .bool(false), "parked": .bool(true)]))
            #expect(model.deferredLinks == [.transcribe(Self.link)])
            #expect(model.recording?.isCapturing == true)
            #expect(model.route == .recording)
        }

        @Test("transcribeYouTube reports a run it really started")
        func transcribeYouTubeReportsStarted() async throws {
            let (model, server, context, commands) = try makeRig()
            model.linkFetcher = FixtureLinkFetcher(fixtureURL: URL(fileURLWithPath: "/tmp/missing-\(UUID()).wav"))
            let command = try #require(commands["transcribeYouTube"])
            let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

            let result = try await command.handler(args, context)
            withExtendedLifetime(server) {}
            model.cancelCurrentWork()

            #expect(result == .object(["started": .bool(true), "parked": .bool(false)]))
            #expect(model.deferredLinks.isEmpty)
        }

        @Test("a link sent while a take transcribes on its Stage waits behind it and leaves the Stage up, so the take lands in place", arguments: [
            "transcribeYouTube", "fetchYouTubeSubs",
        ])
        func linkBehindATakeKeepsItsStage(name: String) async throws {
            let audio = try makeTakeWAV("bridge-link-behind-take", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await installMockTranscriber(segments: [(0, 1, "the take's words")], gate: gate)
                let (model, server, context, commands) = try makeRig()
                model.selectedModel = "openai_whisper-tiny"
                // Fails at once when the link's turn comes, so nothing transcribes after the test.
                model.linkFetcher = ScriptedLinkFetcher(fixture: audio, failure: LinkDownloadFailure(reason: .unreachable))
                recordAndStop(model, audio: audio, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                try #require(transcribing, "the take never transcribed on its Stage")
                let command = try #require(commands[name])
                let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

                let result = try await command.handler(args, context)

                #expect(result == .object(["started": .bool(false), "parked": .bool(true)]))
                #expect(model.route == .recording, "the link took the Stage from the take it waits for")
                await gate.open()
                let landed = await waitUntil { model.takeSavedNotice != nil || model.arrivalNotice?.origin == .take }
                #expect(landed, "the take never landed")
                #expect(model.arrivalNotice?.origin != .take, "the take landed out of sight")
                withExtendedLifetime(server) {}
            }
        }

        @Test("fetchYouTubeSubs owns up to parking a fetch handed over during a take")
        func fetchYouTubeSubsReportsParked() async throws {
            let (model, server, context, commands) = try makeRig()
            model.installTestTake(source: .microphone)
            let command = try #require(commands["fetchYouTubeSubs"])
            let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

            let result = try await command.handler(args, context)
            withExtendedLifetime(server) {}

            #expect(result == .object(["started": .bool(false), "parked": .bool(true)]))
            #expect(model.deferredLinks == [.subtitles(Self.link)])
            #expect(model.recording?.isCapturing == true)
            #expect(model.route == .recording)
        }

        @Test("the bridge refuses both subtitle doors with YouTube off", arguments: [
            "fetchYouTubeSubs", "openYouTubeSheet",
        ])
        func bridgeRefusesYouTubeWhenDisabled(name: String) async throws {
            let allowed = Set(ParolaFeature.allCases).subtracting([.youtube])
            let (model, server, context, commands) = try makeRig(features: allowed)
            let command = try #require(commands[name])
            let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

            await #expect(throws: AutomationError.self) {
                _ = try await command.handler(args, context)
            }
            withExtendedLifetime(server) {}

            #expect(model.youtubeSheetOpen == false)
            #expect(model.deferredLinks.isEmpty)
        }

        @Test("fetchYouTubeSubs refuses without spawning anything when YouTube is off")
        func fetchYouTubeSubsRefusesWhenDisabled() throws {
            let allowed = Set(ParolaFeature.allCases).subtracting([.youtube])
            let (model, server, _, _) = try makeRig(features: allowed)

            let handoff = model.fetchYouTubeSubs(urlString: Self.link)
            withExtendedLifetime(server) {}

            #expect(handoff == .rejected)
            #expect(model.deferredLinks.isEmpty)
            #expect(model.phase == .failed(message: ParolaError.featureDisabled(.youtube).description))
        }

        private static func transcript(_ texts: [String]) -> Transcript {
            Transcript(
                segments: texts.enumerated().map {
                    TranscriptSegment(id: $0.offset, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element)
                },
                language: "en",
                modelName: "tiny"
            )
        }

        /// The subtitles run swaps the pane without a bundle or a player, so nothing else drops a stale reveal,
        /// and segment ids are positions: kept, it would hold an unrelated line of the fetched transcript.
        @Test("a fetched subtitle transcript drops the reveal an earlier search left")
        func fetchedSubtitlesEndAPendingReveal() throws {
            let (model, server, _, _) = try makeRig()
            model.transcript = Self.transcript(["Hello world.", "Hello again.", "Goodbye world!"])
            model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 0))
            try #require(model.pendingRevealSegmentID == 1)

            model.installFetchedSubtitles(Self.transcript(["Fetched captions", "second line"]))
            withExtendedLifetime(server) {}

            #expect(model.pendingRevealSegmentID == nil)
            #expect(model.selectedEntryID == nil)
            #expect(model.transcript?.segments.first?.text == "Fetched captions")
        }

        @Test("a URL yt-dlp cannot take is neither started nor parked")
        func fetchYouTubeSubsReportsRefusal() async throws {
            let (model, server, context, commands) = try makeRig()
            let command = try #require(commands["fetchYouTubeSubs"])
            let args = try command.validate(AutomationArgs(["url": .string("https://example.com/clip")]))

            let result = try await command.handler(args, context)
            withExtendedLifetime(server) {}

            #expect(result == .object(["started": .bool(false), "parked": .bool(false)]))
            #expect(model.deferredLinks.isEmpty)
        }
    }
}
