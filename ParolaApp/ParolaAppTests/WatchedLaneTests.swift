import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Watched-folder lane", .serialized)
    struct WatchedLaneTests {

        private static let appleSpeech = "apple-speech-analyzer"

        private actor Tally {
            var cards = 0
            func card() { cards += 1 }
        }

        @MainActor
        private final class Sounds {
            var plays = 0
        }

        private struct Rig {
            let model: AppModel
            let folder: URL
            let tally: Tally
            let sounds: Sounds
            let recorder: MockDeliveryRecorder
        }

        private func makeRig(_ label: String) throws -> Rig {
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL("watched-lane-\(label)"),
                features: Set(ParolaFeature.allCases)
            )
            model.selectedModel = Self.appleSpeech
            let tally = Tally()
            model.cardMetadataOperation = { _ in
                await tally.card()
                return CardMetadata(title: "Titled", summary: "Summed up.")
            }
            let sounds = Sounds()
            model.completionSoundPlayer = { sounds.plays += 1 }
            model.playSoundWhenFinished = true
            model.sweptFolders = { [] }
            model.autoExportRules = [
                AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])
            ]
            let recorder = MockDeliveryRecorder()
            model.setDestinations([.mock(MockDestination(
                name: "Mock vault", autoSend: true, categories: Set(EntryCategory.allCases), recorder: recorder
            ))])
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-lane-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return Rig(model: model, folder: folder, tally: tally, sounds: sounds, recorder: recorder)
        }

        private func makeWAV(_ name: String, in folder: URL, seconds: Double = 0.3) throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let frames = Int(Double(sampleRate) * seconds)
            let dataBytes = frames * channels * bytesPerSample
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
            le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
            le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
            ascii("data"); le32(UInt32(dataBytes))
            data.append(Data(count: dataBytes))
            let url = folder.appendingPathComponent("\(name).wav")
            try data.write(to: url)
            return url
        }

        private func install(_ gate: MockTranscriberGate, failing: Bool = false) async {
            await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the watched folder")],
                failure: failing ? MockTranscriberFailure(code: .transcriptionFailed, message: "boom") : nil,
                gate: gate
            ))
        }

        /// An entry of the user's own, open with its audio in the player.
        private func openOwnEntry(_ rig: Rig) async throws -> LibraryEntry {
            let audio = try makeWAV("own", in: rig.folder, seconds: 2)
            let entry = try await rig.model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "my own notes")],
                    language: "en", modelName: "stub"
                ),
                audioSource: audio
            )
            try await rig.model.openEntry(entry.id)
            return entry
        }

        private func arrive(_ model: AppModel, _ urls: URL...) {
            for url in urls { model.handleWatchedArrival(url) }
        }

        @Test("an arrival while a transcript is open and playing leaves the window alone and lands out of sight")
        func busyArrivalLandsOutOfSight() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let rig = try makeRig("busy")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let own = try await openOwnEntry(rig)
                model.isPlaying = true
                model.currentTimeSeconds = 12.5
                let player = try #require(model.player)
                let source = model.sourceFileURL
                let route = model.route
                let arrived = try makeWAV("Standup", in: rig.folder)

                arrive(model, arrived)

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                await model.awaitLandingSteps()
                let entries = await model.library.list()
                let landed = try #require(entries.first { $0.id != own.id })
                #expect(model.player === player)
                #expect(model.isPlaying)
                #expect(model.currentTimeSeconds == 12.5)
                #expect(model.transcript?.segments.first?.text == "my own notes")
                #expect(model.selectedEntryID == own.id)
                #expect(model.sourceFileURL == source)
                #expect(model.phase == .ready)
                #expect(model.route == route)
                #expect(model.batchJobs.isEmpty)
                #expect(!model.recentFiles.contains(arrived))
                #expect(model.arrivalNotice?.state == .saved(landed.id))
                #expect(model.arrivalNotice?.name == "Standup")

                model.openArrivalNotice()
                let selectedEntryIDWait = await waitUntil(timeoutMs: 10_000) { model.selectedEntryID == landed.id }
                #expect(selectedEntryIDWait)
                #expect(model.arrivalNotice == nil)
            }
        }

        @Test("an arrival while Parola is idle runs in the window, as a file the user opened")
        func idleArrivalRunsInTheWindow() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let rig = try makeRig("idle")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let arrived = try makeWAV("Idle", in: rig.folder)

                arrive(model, arrived)

                let fileTranscribeTaskWait = await waitUntil { model.fileTranscribeTask != nil }
                #expect(fileTranscribeTaskWait)
                #expect(model.sourceFileURL == arrived)
                await gate.open()
                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle && model.selectedEntryID != nil }
                #expect(watchedLaneIsIdleWait)
                #expect(model.transcript?.segments.first?.text == "from the watched folder")
                #expect(model.phase == .ready)
                #expect(model.arrivalNotice == nil)
                #expect(!model.recentFiles.contains(arrived))
            }
        }

        @Test("a transcript open in a window of its own keeps an arrival out of sight")
        func viewerWindowCountsAsOpen() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let rig = try makeRig("viewer")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let viewed = try await model.library.add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "in its own window")],
                        language: "en", modelName: "stub"
                    ),
                    audioSource: nil
                )
                _ = model.entryWindows.session(for: viewed.id, model: model)
                #expect(!model.arrivalMayTakeWindow)

                arrive(model, try makeWAV("Beside", in: rig.folder))

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                #expect(model.transcript == nil)
                #expect(model.phase == .idle)
                #expect(model.recentFiles.isEmpty)
                let arrivalNoticeWait = await waitUntil(timeoutMs: 10_000) { model.arrivalNotice != nil }
                #expect(arrivalNoticeWait)
            }
        }

        @Test("an arrival that took the idle window lands out of sight once the user opens something else")
        func windowRunGivesWayToAnOpenedEntry() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let rig = try makeRig("moved-on")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let arrived = try makeWAV("Arrived", in: rig.folder)
                arrive(model, arrived)
                let visibleArrivalIDWait = await waitUntil(timeoutMs: 10_000) { model.visibleArrivalID != nil }
                #expect(visibleArrivalIDWait)

                let own = try await openOwnEntry(rig)
                model.isPlaying = true
                let player = try #require(model.player)
                await gate.open()

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                await model.awaitLandingSteps()
                let landed = try #require(await model.library.list().first { $0.id != own.id })
                #expect(model.selectedEntryID == own.id)
                #expect(model.transcript?.segments.first?.text == "my own notes")
                #expect(model.player === player)
                #expect(model.isPlaying)
                #expect(model.phase == .ready)
                #expect(model.arrivalNotice?.state == .saved(landed.id))
            }
        }

        @Test("an arrival that took the idle window and then fails says so in a toast, not over what the user opened")
        func windowRunFailureStaysOutOfTheWay() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate, failing: true)
                let rig = try makeRig("moved-on-failed")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let arrived = try makeWAV("Broken", in: rig.folder)
                arrive(model, arrived)
                let visibleArrivalIDWait = await waitUntil(timeoutMs: 10_000) { model.visibleArrivalID != nil }
                #expect(visibleArrivalIDWait)

                let own = try await openOwnEntry(rig)
                await gate.open()

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle && model.fileTranscribeTask == nil }
                #expect(watchedLaneIsIdleWait)
                #expect(model.phase == .ready)
                #expect(model.selectedEntryID == own.id)
                #expect(model.transcript?.segments.first?.text == "my own notes")
                #expect(model.failedFileURL == nil)
                #expect(model.arrivalNotice?.name == "Broken")
                guard case .failed = model.arrivalNotice?.state else {
                    Issue.record("expected a failure toast")
                    return
                }
            }
        }

        @Test("a burst of five lands every file with the same post-run steps")
        func burstLandsThroughOnePath() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let rig = try makeRig("burst")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                var files: [URL] = []
                for index in 1...5 {
                    files.append(try makeWAV("Memo \(index)", in: rig.folder, seconds: 0.2 + Double(index) / 10))
                }

                for file in files { model.handleWatchedArrival(file) }
                #expect(model.watchedArrivals.map(\.url) == files)
                await gate.open()

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 5 }
                #expect(libraryWait)
                await model.awaitLandingSteps()
                await model.awaitCardMetadataQueue()
                let rigWait = await waitUntil(timeoutMs: 10_000) { await rig.recorder.recorded().count == 5 }
                #expect(rigWait)
                let sidecars = try FileManager.default.contentsOfDirectory(atPath: rig.folder.path)
                    .filter { $0.hasSuffix(".txt") }
                #expect(Set(sidecars) == Set(files.map { $0.deletingPathExtension().lastPathComponent + ".txt" }))
                #expect(await rig.tally.cards == 5)
                #expect(model.batchJobs.isEmpty)
                #expect(model.route == .transcript)
                // The first file ran in the window and rang; the rest rang once, when the lane ran dry.
                #expect(rig.sounds.plays == 2)
            }
        }

        @Test("a file offered again while it runs waits once behind itself, however often it is offered")
        func reofferedFileWaitsOnce() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let rig = try makeRig("reoffer")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                _ = try await openOwnEntry(rig)
                let file = try makeWAV("Growing", in: rig.folder)
                let other = try makeWAV("Other", in: rig.folder, seconds: 0.5)
                arrive(model, file)
                let backgroundArrivalIDWait = await waitUntil { model.backgroundArrivalID != nil }
                #expect(backgroundArrivalIDWait)

                arrive(model, file)
                arrive(model, other)
                arrive(model, file)

                #expect(model.watchedArrivals.map(\.url) == [file, file, other])
                await gate.open()
                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
            }
        }

        @Test("a file the user opens takes the session from a file out of sight, which then finishes")
        func foregroundPreemptsTheLane() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let rig = try makeRig("preempt")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let own = try await openOwnEntry(rig)
                let arrived = try makeWAV("Arrived", in: rig.folder)
                let opened = try makeWAV("Opened", in: rig.folder, seconds: 0.5)

                arrive(model, arrived)
                let backgroundArrivalIDWait = await waitUntil { model.backgroundArrivalID != nil }
                #expect(backgroundArrivalIDWait)

                model.transcribe(fileURL: opened)
                let fileTranscribeTaskWait = await waitUntil(timeoutMs: 10_000) { model.fileTranscribeTask != nil }
                #expect(fileTranscribeTaskWait)
                #expect(model.watchedLaneTask == nil)
                #expect(model.watchedArrivals.map(\.url) == [arrived])
                await gate.open()

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle && model.fileTranscribeTask == nil }
                #expect(watchedLaneIsIdleWait)
                let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 3 }
                #expect(libraryWait)
                let titles = Set(await model.library.list().filter { $0.id != own.id }.map(LibraryEntryDisplay.title(for:)))
                #expect(titles == ["Arrived", "Opened"])
            }
        }

        @Test("a watched file deleted before its turn leaves the line without a run or a toast")
        func missingArrivalIsDropped() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let rig = try makeRig("missing")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                let gone = try makeWAV("Gone", in: rig.folder)
                model.fileTranscribeTask = Task {}
                arrive(model, gone)
                #expect(model.watchedArrivals.map(\.url) == [gone])
                try FileManager.default.removeItem(at: gone)

                model.fileTranscribeTask = nil

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                #expect(model.arrivalNotice == nil)
                #expect(model.fileTranscribeTask == nil)
                #expect(await model.library.list().isEmpty)
            }
        }

        @Test("a file that fails out of sight leaves the line and the toast says why")
        func backgroundFailureIsAnnounced() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate, failing: true)
                await gate.open()
                let rig = try makeRig("failure")
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                let model = rig.model
                _ = try await openOwnEntry(rig)
                let arrived = try makeWAV("Broken", in: rig.folder)

                arrive(model, arrived)

                let watchedLaneIsIdleWait = await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle }
                #expect(watchedLaneIsIdleWait)
                #expect(model.arrivalNotice?.name == "Broken")
                guard case .failed(let reason) = model.arrivalNotice?.state else {
                    Issue.record("expected a failure notice")
                    return
                }
                #expect(reason.contains("boom"))
                #expect(model.phase == .ready)
            }
        }
    }
}
