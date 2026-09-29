import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Foreground slot")
struct ForegroundSlotTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("foreground-slot"),
            features: Set(ParolaFeature.allCases).subtracting([.batch])
        )
    }

    @Test("letting go drains on the next turn, not inside the setter")
    func drainWaitsForTheNextTurn() async {
        let model = makeModel()
        let parked = URL(fileURLWithPath: "/tmp/parola-slot-\(UUID().uuidString).parola")
        model.fileTranscribeTask = Task {}
        model.deferredArrivals = [parked]

        model.fileTranscribeTask = nil

        #expect(model.deferredArrivals == [parked])
        await model.awaitArrivalDrain()
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test("a drain waits while anything else still holds the foreground", arguments: [
        "recording", "duplicate sheet", "duplicate check",
    ])
    func drainWaitsForEveryHolder(holder: String) async {
        let model = makeModel()
        let parked = URL(fileURLWithPath: "/tmp/parola-slot-\(UUID().uuidString).parola")
        model.fileTranscribeTask = Task {}
        model.deferredArrivals = [parked]
        switch holder {
        case "recording": model.phase = .recording(source: .microphone)
        case "duplicate sheet": model.duplicateImport = DuplicateImport(
            entryID: "e", entryTitle: "t", modelName: "m", createdAt: Date(), durationSeconds: nil,
            fileURL: parked, digest: "d", translateOverride: nil
        )
        default: model.duplicateCheckTask = Task {}
        }

        model.fileTranscribeTask = nil
        await model.awaitArrivalDrain()
        #expect(model.deferredArrivals == [parked])

        switch holder {
        case "recording": model.phase = .idle
        case "duplicate sheet": model.duplicateImport = nil
        default: model.duplicateCheckTask = nil
        }
        await model.awaitArrivalDrain()
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test("a parked file deleted before its turn is dropped when the drain comes")
    func missingParkedFileIsDropped() async throws {
        let model = makeModel()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-slot-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = folder.appendingPathComponent("gone.wav")
        try Data("RIFF".utf8).write(to: gone)
        model.fileTranscribeTask = Task {}
        model.transcribeNow(urls: [gone])
        #expect(model.deferredArrivals == [gone])
        try FileManager.default.removeItem(at: gone)

        model.fileTranscribeTask = nil
        await model.awaitArrivalDrain()

        #expect(model.deferredArrivals.isEmpty)
        #expect(model.duplicateCheckTask == nil)
        #expect(model.fileTranscribeTask == nil)
        #expect(!model.recentFiles.contains(gone))
    }
}

extension ForegroundSlotTests {
    @Test("a parked file on a share that stops answering is kept and still drains once the check gives up")
    func stalledCheckKeepsTheFile() async {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("foreground-slot-stalled"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ContinuousClock(),
            fileReadDeadline: .milliseconds(200)
        )
        let model = AppModel(bootstrap: bootstrap)
        let stall = DispatchSemaphore(value: 0)
        defer { stall.signal() }
        model.parkedFileProbe = { _ in
            stall.wait()
            return false
        }
        let parked = URL(fileURLWithPath: "/tmp/parola-slot-\(UUID().uuidString).wav")
        model.fileTranscribeTask = Task {}
        model.deferredArrivals = [parked]

        let started = ContinuousClock.now
        model.fileTranscribeTask = nil
        await model.awaitArrivalDrain()
        await model.awaitBatchImport()

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.map(\.url) == [parked])
        model.clearBatch()
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Arrival drain", .serialized)
    struct ArrivalDrainTests {

        private static let appleSpeech = "apple-speech-analyzer"

        private func makeModel(_ label: String) -> AppModel {
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL("arrival-drain-\(label)"),
                features: Set(ParolaFeature.allCases).subtracting([.batch])
            )
            model.selectedModel = Self.appleSpeech
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func makeWAV(_ label: String, seconds: Double = 0.3) throws -> URL {
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
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-drain-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func install(_ gate: MockTranscriberGate, failing: Bool = false) async {
            await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "drained")],
                failure: failing ? MockTranscriberFailure(code: .transcriptionFailed, message: "boom") : nil,
                gate: gate
            ))
        }

        /// The first file runs and the second waits behind it, the way a two-file drop starts.
        private func startWithOneParked(_ model: AppModel, _ first: URL, _ second: URL) async -> Bool {
            model.transcribeNow(urls: [first, second])
            guard model.deferredArrivals == [second] else { return false }
            return await waitUntil(timeoutMs: 10_000) { model.fileTranscribeTask != nil }
        }

        /// A file run notes its file in Open Recent as it starts.
        private func secondStarted(_ model: AppModel, _ second: URL) async -> Bool {
            await model.awaitArrivalDrain()
            return await waitUntil(timeoutMs: 10_000) {
                model.deferredArrivals.isEmpty && model.recentFiles.contains(second)
            }
        }

        @Test("a run that lands lets the file parked behind it go")
        func successDrains() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let model = makeModel("success")
                let first = try makeWAV("success-1")
                let second = try makeWAV("success-2", seconds: 0.4)
                defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
                #expect(await startWithOneParked(model, first, second))

                await gate.open()

                #expect(await waitUntil(timeoutMs: 10_000) { model.transcript?.segments.first?.text == "drained" })
                #expect(await secondStarted(model, second))
                model.cancelCurrentWork()
            }
        }

        @Test("a run that fails lets the file parked behind it go")
        func failureDrains() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate, failing: true)
                let model = makeModel("failure")
                let first = try makeWAV("failure-1")
                let second = try makeWAV("failure-2", seconds: 0.4)
                defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
                #expect(await startWithOneParked(model, first, second))

                await gate.open()

                #expect(await secondStarted(model, second))
                model.cancelCurrentWork()
            }
        }

        enum Answer: String, CaseIterable {
            case openExisting, dismiss, transcribeAgain
        }

        @Test("the duplicate sheet holds the files behind it until it is answered", arguments: Answer.allCases)
        func duplicateSheetDrains(answer: Answer) async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                await gate.open()
                let model = makeModel("sheet-\(answer.rawValue)")
                let known = try makeWAV("sheet-known")
                let second = try makeWAV("sheet-second", seconds: 0.4)
                defer { for url in [known, second] { try? FileManager.default.removeItem(at: url) } }
                _ = try await model.library.add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "already here")],
                        language: "en", modelName: "stub"
                    ),
                    audioSource: known
                )

                model.transcribeNow(urls: [known, second])
                await model.awaitDuplicateCheck()
                #expect(model.duplicateImport != nil)
                await model.awaitArrivalDrain()
                #expect(model.deferredArrivals == [second])

                switch answer {
                case .openExisting: model.openExistingDuplicate(remembering: false)
                case .dismiss: model.dismissDuplicateImport()
                case .transcribeAgain: model.transcribeDuplicateAgain(remembering: false)
                }

                #expect(await secondStarted(model, second))
                model.cancelCurrentWork()
            }
        }

        @Test("a re-run lets the file parked behind it go")
        func rerunDrains() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await install(gate)
                let model = makeModel("rerun")
                let audio = try makeWAV("rerun-audio")
                let second = try makeWAV("rerun-second", seconds: 0.4)
                defer { for url in [audio, second] { try? FileManager.default.removeItem(at: url) } }
                let entry = try await model.library.add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the first run")],
                        language: "en", modelName: "stub"
                    ),
                    audioSource: audio
                )
                try await model.openEntry(entry.id)
                model.refreshLibrary()
                #expect(await waitUntil(timeoutMs: 10_000) { model.libraryEntry(id: entry.id) != nil })

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: nil)
                model.transcribeNow(urls: [second])
                #expect(model.deferredArrivals == [second])

                await gate.open()

                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await secondStarted(model, second))
                model.cancelCurrentWork()
            }
        }
    }
}
