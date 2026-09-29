import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Watched arrivals are never dropped", .serialized)
    struct WatchedArrivalLossTests {

        private static let appleSpeech = "apple-speech-analyzer"

        @MainActor
        private final class HandedBack {
            var urls: [URL] = []
        }

        private func makeModel(library: URL, defaults: UserDefaults) -> AppModel {
            let model = AppModel(
                skipBootstrap: true,
                defaults: defaults,
                libraryURL: library,
                features: Set(ParolaFeature.allCases)
            )
            model.selectedModel = Self.appleSpeech
            model.cardMetadataOperation = { _ in nil }
            model.sweptFolders = { [] }
            return model
        }

        private func makeFolder(_ label: String) throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-loss-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
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
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "kept")],
                failure: failing ? MockTranscriberFailure(code: .transcriptionFailed, message: "boom") : nil,
                gate: gate
            ))
        }

        private func arrive(_ model: AppModel, _ urls: [URL]) {
            for url in urls { model.handleWatchedArrival(url) }
        }

        /// An entry of the user's own on screen, so arrivals run out of sight.
        private func openOwnEntry(_ model: AppModel, in folder: URL) async throws -> LibraryEntry {
            let entry = try await model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "my own notes")],
                    language: "en", modelName: "stub"
                ),
                audioSource: try makeWAV("own", in: folder, seconds: 1)
            )
            try await model.openEntry(entry.id)
            return entry
        }

        private func savedQueue(_ model: AppModel) throws -> [URL] {
            let data = try Data(contentsOf: model.watchedArrivalsFileURL)
            return try JSONDecoder().decode([WatchedArrival].self, from: data).map(\.url)
        }

        @Test("files waiting behind a run when Parola quits come back at the next launch and land")
        func waitingArrivalsSurviveAQuit() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("quit")
                defer { try? FileManager.default.removeItem(at: folder) }
                let library = makeTempLibraryURL("loss-quit")
                let defaults = temporaryDefaults()
                let files = [try makeWAV("One", in: folder), try makeWAV("Two", in: folder, seconds: 0.4)]
                do {
                    let before = makeModel(library: library, defaults: defaults)
                    before.fileTranscribeTask = Task {}
                    arrive(before, files)
                    #expect(try savedQueue(before) == files)
                }

                let after = makeModel(library: library, defaults: defaults)
                #expect(after.watchedArrivals.map(\.url) == files)
                let digests = after.watchedArrivals.compactMap(\.sourceDigest)
                #expect(digests.isEmpty)
                await gate.open()

                #expect(await waitUntil(timeoutMs: 20_000) { after.watchedLaneIsIdle })
                #expect(await waitUntil(timeoutMs: 10_000) { await after.library.list().count == 2 })
                #expect(!FileManager.default.fileExists(atPath: after.watchedArrivalsFileURL.path))
            }
        }

        @Test("files are saved to the line as they are handed over, so a quit during the duplicate check keeps them")
        func arrivalsAreSavedBeforeTheCheck() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let folder = try makeFolder("quit-checking")
                defer { try? FileManager.default.removeItem(at: folder) }
                let library = makeTempLibraryURL("loss-quit-checking")
                let defaults = temporaryDefaults()
                let files = [
                    try makeWAV("One", in: folder), try makeWAV("Two", in: folder, seconds: 0.4),
                    try makeWAV("Three", in: folder, seconds: 0.5),
                ]
                do {
                    let before = makeModel(library: library, defaults: defaults)
                    arrive(before, files)
                    #expect(before.watchedLaneTask != nil, "the first file's check is under way")
                    #expect(before.backgroundArrivalID == nil && before.visibleArrivalID == nil)
                    #expect(try savedQueue(before) == files)
                    before.preemptWatchedLane()
                }

                let after = makeModel(library: library, defaults: defaults)
                #expect(after.watchedArrivals.map(\.url) == files)
                #expect(await waitUntil(timeoutMs: 20_000) { after.watchedLaneIsIdle })
                #expect(await waitUntil(timeoutMs: 10_000) { await after.library.list().count == 3 })
            }
        }

        @Test("a file the library already holds is skipped by the check before its run, even after a quit")
        func duplicateIsSkippedBeforeItsRun() async throws {
            let folder = try makeFolder("duplicate")
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = makeModel(library: makeTempLibraryURL("loss-duplicate"), defaults: temporaryDefaults())
            let file = try makeWAV("Known", in: folder)
            _ = try await model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "already here")],
                    language: "en", modelName: "stub"
                ),
                audioSource: file
            )
            model.watchedArrivals = [WatchedArrival(url: file)]

            model.pumpWatchedLane()

            #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle })
            #expect(model.batchDuplicatesSkipped == 1)
            #expect(model.fileTranscribeTask == nil)
            #expect(await model.library.list().count == 1)
        }

        @Test("a file running out of sight when Parola quits comes back at the next launch")
        func runningArrivalSurvivesAQuit() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("quit-running")
                defer { try? FileManager.default.removeItem(at: folder) }
                let library = makeTempLibraryURL("loss-quit-running")
                let defaults = temporaryDefaults()
                let file = try makeWAV("Running", in: folder)
                do {
                    let before = makeModel(library: library, defaults: defaults)
                    _ = try await openOwnEntry(before, in: folder)
                    arrive(before, [file])
                    #expect(await waitUntil { before.backgroundArrivalID != nil })
                    #expect(try savedQueue(before) == [file])
                    before.preemptWatchedLane()
                }

                let after = makeModel(library: library, defaults: defaults)
                #expect(after.watchedArrivals.map(\.url) == [file])
                await gate.open()
                #expect(await waitUntil(timeoutMs: 20_000) { after.watchedLaneIsIdle })
                let titles = await after.library.list().map(LibraryEntryDisplay.title(for:))
                #expect(titles.contains("Running"))
            }
        }

        @Test("a file whose entry is still being saved when Parola quits runs again at the next launch")
        func landingArrivalSurvivesAQuit() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let folder = try makeFolder("quit-landing")
                defer { try? FileManager.default.removeItem(at: folder) }
                let library = makeTempLibraryURL("loss-quit-landing")
                let defaults = temporaryDefaults()
                let file = try makeWAV("Copying", in: folder)
                let (held, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                do {
                    let before = makeModel(library: library, defaults: defaults)
                    before.beforeLandingSave = {
                        for await _ in held {}
                        throw CancellationError()
                    }
                    _ = try await openOwnEntry(before, in: folder)
                    arrive(before, [file])
                    #expect(await waitUntil(timeoutMs: 10_000) { before.watchedArrivals.first?.isLanding == true })
                    #expect(try savedQueue(before) == [file])
                }

                let after = makeModel(library: library, defaults: defaults)
                #expect(after.watchedArrivals.map(\.url) == [file])
                #expect(after.watchedArrivals.first?.isLanding == false)
                #expect(await waitUntil(timeoutMs: 20_000) { after.watchedLaneIsIdle })
                let titles = await after.library.list().map(LibraryEntryDisplay.title(for:))
                #expect(titles.contains("Copying"))
            }
        }

        @Test("a file whose entry couldn't be saved is handed back to its watcher", arguments: [false, true])
        func failedSaveIsHandedBack(outOfSight: Bool) async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let folder = try makeFolder("save-failed-\(outOfSight)")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-save-failed"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                if outOfSight { _ = try await openOwnEntry(model, in: folder) }
                model.beforeLandingSave = { throw CocoaError(.fileWriteOutOfSpace) }
                let file = try makeWAV("Unsaved", in: folder)

                arrive(model, [file])

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle })
                #expect(handedBack.urls == [file])
                #expect(model.nonFatalWarning?.contains("couldn't save it to your library") == true)
                #expect(!FileManager.default.fileExists(atPath: model.watchedArrivalsFileURL.path))
            }
        }

        @Test("Cancel stops the file in the window for good, hands it back, and lets the rest finish out of sight")
        func cancelStopsTheWindowRunOnly() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("cancel")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-cancel"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                let files = [try makeWAV("First", in: folder), try makeWAV("Second", in: folder, seconds: 0.4)]
                arrive(model, files)
                #expect(await waitUntil { model.visibleArrivalID != nil })
                #expect(model.fileTranscribeTask != nil)

                model.cancelCurrentWork()

                #expect(model.visibleArrivalID == nil)
                #expect(handedBack.urls == [files[0]])
                #expect(model.watchedArrivals.map(\.url) == [files[1]])
                #expect(model.watchedArrivals.first?.inBackground == true)
                await gate.open()
                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                let titles = await model.library.list().map(LibraryEntryDisplay.title(for:))
                #expect(titles == ["Second"])
                #expect(model.transcript == nil)
                #expect(model.phase == .idle)
                #expect(model.arrivalNotice?.name == "Second")
            }
        }

        @Test("Stop on the running strip stops the file out of sight, hands it back, and the next one runs")
        func stopEndsTheBackgroundRun() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("stop")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-stop"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                let own = try await openOwnEntry(model, in: folder)
                let files = [try makeWAV("Long", in: folder), try makeWAV("Short", in: folder, seconds: 0.4)]
                arrive(model, files)
                #expect(await waitUntil(timeoutMs: 10_000) { model.backgroundArrivalID != nil })
                #expect(model.runningArrivalNotice?.name == "Long")
                #expect(model.runningArrivalNotice?.state == .running)

                model.stopBackgroundArrival()

                #expect(handedBack.urls == [files[0]])
                #expect(model.watchedArrivals.map(\.url) == [files[1]])
                await gate.open()
                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                let titles = await model.library.list().filter { $0.id != own.id }.map(LibraryEntryDisplay.title(for:))
                #expect(titles == ["Short"])
                #expect(model.runningArrivalNotice == nil)
                #expect(model.selectedEntryID == own.id)
            }
        }

        @Test("a file the user opens takes the window from an arrival, which goes back to the head of the line")
        func userRunPreemptsTheVisibleArrival() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("preempt-visible")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-preempt"), defaults: temporaryDefaults())
                let arrived = try makeWAV("Arrived", in: folder)
                let later = try makeWAV("Later", in: folder, seconds: 0.5)
                let opened = try makeWAV("Opened", in: folder, seconds: 0.6)
                arrive(model, [arrived])
                #expect(await waitUntil { model.visibleArrivalID != nil })
                arrive(model, [later])

                model.transcribe(fileURL: opened)
                #expect(await waitUntil(timeoutMs: 10_000) { model.sourceFileURL == opened })

                #expect(model.visibleArrivalID == nil)
                #expect(model.watchedArrivals.map(\.url) == [arrived, later])
                #expect(model.watchedArrivals.first?.inBackground == true)
                await gate.open()
                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle && model.fileTranscribeTask == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 3 })
                #expect(model.transcript?.segments.first?.text == "kept")
                #expect(model.sourceFileURL == opened)
            }
        }

        private actor Calls {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }

        @Test("a run in the window replaced while it post-processes lands once, out of sight, not twice")
        func replacedDuringPostProcessingLandsOnce() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let folder = try makeFolder("postprocess")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-postprocess"), defaults: temporaryDefaults())
                let calls = Calls()
                let (held, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                model.postProcessOperation = { transcript in
                    if await calls.next() == 1 {
                        for await _ in held { break }
                    }
                    return transcript
                }
                let arrived = try makeWAV("Arrived", in: folder)
                let opened = try makeWAV("Opened", in: folder, seconds: 0.6)
                arrive(model, [arrived])
                #expect(await waitUntil(timeoutMs: 10_000) { await calls.count == 1 })

                model.transcribe(fileURL: opened)
                #expect(await waitUntil(timeoutMs: 10_000) { model.sourceFileURL == opened })
                release.yield()

                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle && model.fileTranscribeTask == nil })
                await model.awaitLandingSteps()
                await settle()
                let titles = await model.library.list().map(LibraryEntryDisplay.title(for:)).sorted()
                #expect(titles == ["Arrived", "Opened"])
                #expect(model.sourceFileURL?.lastPathComponent == "Opened.wav")
            }
        }

        @Test("a file whose folder is missing keeps its place, lets the rest go, and runs when the folder is back")
        func unreachableFolderKeepsItsFiles() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let root = try makeFolder("unreachable")
                defer { try? FileManager.default.removeItem(at: root) }
                let share = root.appendingPathComponent("Share", isDirectory: true)
                let local = root.appendingPathComponent("Local", isDirectory: true)
                let away = root.appendingPathComponent("Unmounted", isDirectory: true)
                for folder in [share, local] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                let model = makeModel(library: makeTempLibraryURL("loss-unreachable"), defaults: temporaryDefaults())
                _ = try await openOwnEntry(model, in: root)
                let onShare = try makeWAV("On the share", in: share)
                let onDisk = try makeWAV("On the disk", in: local, seconds: 0.5)
                model.fileTranscribeTask = Task {}
                arrive(model, [onShare, onDisk])
                try FileManager.default.moveItem(at: share, to: away)

                model.fileTranscribeTask = nil

                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedArrivals.map(\.url) == [onShare] })
                #expect(model.watchedLaneTask == nil)
                #expect(model.unreachableArrivalIDs == Set(model.watchedArrivals.map(\.id)))
                #expect(await model.library.list().map(LibraryEntryDisplay.title(for:)).contains("On the disk"))

                try FileManager.default.moveItem(at: away, to: share)
                model.retryUnreachableArrivals()

                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                #expect(await model.library.list().map(LibraryEntryDisplay.title(for:)).contains("On the share"))
            }
        }

        @Test("a folder that doesn't answer before the deadline keeps its file waiting")
        func stalledFolderKeepsItsFile() async throws {
            let folder = try makeFolder("stalled")
            defer { try? FileManager.default.removeItem(at: folder) }
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("loss-stalled"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock(),
                fileReadDeadline: .milliseconds(200)
            )
            let model = AppModel(bootstrap: bootstrap)
            let stall = DispatchSemaphore(value: 0)
            defer { stall.signal() }
            model.watchedFileReach = { _, _ in
                stall.wait()
                return .gone
            }
            let file = try makeWAV("Stalled", in: folder)

            arrive(model, [file])

            #expect(await waitUntil(timeoutMs: 5_000) { !model.unreachableArrivalIDs.isEmpty })
            #expect(model.watchedArrivals.map(\.url) == [file])
            #expect(model.watchedLaneTask == nil)
            #expect(model.fileTranscribeTask == nil)
            model.watchedArrivals = []
        }

        private func installChecksumFailure() async {
            await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                failure: MockTranscriberFailure(code: .modelChecksumMismatch, message: "weights")
            ))
        }

        @Test("a model failure stops the lane with every file still waiting, and Retry lands them all")
        func modelFailurePausesTheLane() async throws {
            try await withMocksCleared(.transcriber) {
                await installChecksumFailure()
                let folder = try makeFolder("paused")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-paused"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                let own = try await openOwnEntry(model, in: folder)
                let files = [try makeWAV("First", in: folder), try makeWAV("Second", in: folder, seconds: 0.4)]

                arrive(model, files)

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLanePausedAt != nil })
                await settle()
                #expect(model.watchedArrivals.map(\.url) == files)
                #expect(model.watchedLaneTask == nil)
                #expect(handedBack.urls.isEmpty)
                guard case .paused = model.arrivalNotice?.state else {
                    Issue.record("expected the lane to say it stopped")
                    return
                }
                #expect(model.arrivalNotice?.name == "First")

                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                // The session keeps the engine it loaded; dropping it picks up the working mock.
                await model.unloadTranscriptionSession()
                model.resumeWatchedLane()

                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                let titles = await model.library.list().filter { $0.id != own.id }.map(LibraryEntryDisplay.title(for:))
                #expect(Set(titles) == ["First", "Second"])
            }
        }

        @Test("a stopped lane starts again once a later foreground run lets go, not on the let-go of the run that failed")
        func pausedLaneResumesOnTheNextLetGo() async throws {
            try await withMocksCleared(.transcriber) {
                await installChecksumFailure()
                let folder = try makeFolder("paused-letgo")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-paused-letgo"), defaults: temporaryDefaults())
                let file = try makeWAV("Waiting", in: folder)

                arrive(model, [file])

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLanePausedAt != nil })
                await model.awaitArrivalDrain()
                #expect(model.watchedLanePausedAt != nil, "the failing run's own let-go leaves the lane stopped")
                #expect(model.watchedArrivals.map(\.url) == [file])
                #expect(model.failedFileURL == file)

                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                await model.unloadTranscriptionSession()
                model.fileTranscribeTask = Task {}
                model.fileTranscribeTask = nil
                await model.awaitArrivalDrain()

                #expect(model.watchedLanePausedAt == nil)
                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                #expect(await model.library.list().count == 1)
            }
        }

        @Test("Retry on the error pane of a watched file that stopped the lane starts the lane, not a second copy")
        func errorPaneRetryResumesTheLane() async throws {
            try await withMocksCleared(.transcriber) {
                await installChecksumFailure()
                let folder = try makeFolder("paused-retry")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-paused-retry"), defaults: temporaryDefaults())
                let file = try makeWAV("Retried", in: folder)
                arrive(model, [file])
                #expect(await waitUntil(timeoutMs: 10_000) {
                    model.watchedLanePausedAt != nil && model.canRetryFailedTranscription
                })

                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                await model.unloadTranscriptionSession()
                model.retryFailedTranscription()

                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                #expect(await model.library.list().count == 1)
                #expect(!model.recentFiles.contains(file))
            }
        }

        @Test("a speaker model that can't load stops the lane with both files waiting; a file that won't decode leaves alone")
        func engineLoadFailurePausesDecodeFailureDrops() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .engineLoadFailed, message: "SpeakerKit init failed: offline")
                ))
                let folder = try makeFolder("engine-load")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-engine-load"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                _ = try await openOwnEntry(model, in: folder)
                let files = [try makeWAV("First", in: folder), try makeWAV("Second", in: folder, seconds: 0.4)]

                arrive(model, files)

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLanePausedAt != nil })
                #expect(model.watchedArrivals.map(\.url) == files)
                #expect(handedBack.urls.isEmpty)

                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "not audio")
                ))
                await model.unloadTranscriptionSession()
                model.resumeWatchedLane()

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle })
                #expect(handedBack.urls == files)
            }
        }

        @Test("what stops the lane: engine, model and network failures, never a file's own")
        func whatStopsTheLane() {
            #expect(AppModel.stopsWatchedLane(ParolaError.engineLoadFailed("model load failed")))
            #expect(AppModel.stopsWatchedLane(ParolaError.modelDownloadFailed("m", underlying: "offline")))
            #expect(AppModel.stopsWatchedLane(URLError(.notConnectedToInternet)))
            #expect(!AppModel.stopsWatchedLane(ParolaError.transcriptionFailed("WhisperKit returned no results")))
            #expect(!AppModel.stopsWatchedLane(ParolaError.unreadableFile(name: "a.wav", reason: nil)))
        }

        @Test("a settings reset leaves the files waiting in the line")
        func settingsResetKeepsTheLine() async throws {
            let folder = try makeFolder("reset")
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = makeModel(library: makeTempLibraryURL("loss-reset"), defaults: temporaryDefaults())
            model.fileTranscribeTask = Task {}
            let file = try makeWAV("Waiting", in: folder)
            arrive(model, [file])

            model.reloadSettings()

            #expect(model.watchedArrivals.map(\.url) == [file])
            #expect(try savedQueue(model) == [file])
            model.watchedArrivals = []
            model.fileTranscribeTask = nil
        }

        @Test("a file that fails, in the window or out of sight, is handed back to its watcher", arguments: [false, true])
        func failedArrivalIsHandedBack(outOfSight: Bool) async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate, failing: true)
                await gate.open()
                let folder = try makeFolder("failed-\(outOfSight)")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-failed"), defaults: temporaryDefaults())
                let handedBack = HandedBack()
                model.offerWatchedFileAgain = { handedBack.urls.append($0) }
                if outOfSight { _ = try await openOwnEntry(model, in: folder) }
                let file = try makeWAV("Broken", in: folder)

                arrive(model, [file])

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle })
                #expect(handedBack.urls == [file])
                if outOfSight {
                    #expect(model.arrivalNotice?.name == "Broken")
                } else {
                    #expect(model.failedFileURL == file)
                }
            }
        }
    }
}
