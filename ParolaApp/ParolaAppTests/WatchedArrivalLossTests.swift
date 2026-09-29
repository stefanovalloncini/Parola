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

        private func arrive(_ model: AppModel, _ urls: [URL]) async {
            for url in urls { model.handleWatchedArrival(url) }
            await model.awaitWatchedImport()
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
                    await arrive(before, files)
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
                    await arrive(before, [file])
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
                    await arrive(before, [file])
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

                await arrive(model, [file])

                #expect(await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle })
                #expect(handedBack.urls == [file])
                #expect(model.nonFatalWarning?.contains("couldn't save it to your library") == true)
                #expect(!FileManager.default.fileExists(atPath: model.watchedArrivalsFileURL.path))
            }
        }

        @Test("Cancel stops the run in the window and leaves every watched file to finish out of sight")
        func cancelLeavesArrivalsAlone() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let folder = try makeFolder("cancel")
                defer { try? FileManager.default.removeItem(at: folder) }
                let model = makeModel(library: makeTempLibraryURL("loss-cancel"), defaults: temporaryDefaults())
                let files = [try makeWAV("First", in: folder), try makeWAV("Second", in: folder, seconds: 0.4)]
                await arrive(model, files)
                #expect(await waitUntil { model.visibleArrivalID != nil })
                #expect(model.fileTranscribeTask != nil)

                model.cancelCurrentWork()

                #expect(model.visibleArrivalID == nil)
                #expect(model.watchedArrivals.map(\.url) == files)
                let outOfSight = model.watchedArrivals.allSatisfy { $0.inBackground }
                #expect(outOfSight)
                await gate.open()
                #expect(await waitUntil(timeoutMs: 20_000) { model.watchedLaneIsIdle })
                #expect(await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 2 })
                #expect(model.transcript == nil)
                #expect(model.phase == .idle)
                #expect(model.arrivalNotice != nil)
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
                await arrive(model, [arrived])
                #expect(await waitUntil { model.visibleArrivalID != nil })
                await arrive(model, [later])

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
                await arrive(model, [arrived])
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

        @Test("a settings reset leaves the files waiting in the line")
        func settingsResetKeepsTheLine() async throws {
            let folder = try makeFolder("reset")
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = makeModel(library: makeTempLibraryURL("loss-reset"), defaults: temporaryDefaults())
            model.fileTranscribeTask = Task {}
            let file = try makeWAV("Waiting", in: folder)
            await arrive(model, [file])

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

                await arrive(model, [file])

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
