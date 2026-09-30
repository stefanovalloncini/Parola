import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

private func makeSilentWAV() throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * 0.3)
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
        .appendingPathComponent("parola-diskguard-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Disk space guard", .serialized)
    struct DiskSpaceGuardTests {

        private func makeModel(clock: any Clock<Duration> = ContinuousClock()) -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("diskguard"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: clock
            )
            return AppModel(bootstrap: bootstrap)
        }

        private func waitUntil(timeoutMs: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        private func isRecording(_ model: AppModel) -> Bool {
            if case .recording = model.phase { return true }
            return false
        }

        @Test("verdict: refuse under 200 MB, warn under 1 GB, ok above or unknown")
        func verdictThresholds() {
            #expect(AppModel.diskSpaceVerdict(freeBytes: 0) == .refuse)
            #expect(AppModel.diskSpaceVerdict(freeBytes: 199_999_999) == .refuse)
            #expect(AppModel.diskSpaceVerdict(freeBytes: 200_000_000) == .warn)
            #expect(AppModel.diskSpaceVerdict(freeBytes: 999_999_999) == .warn)
            #expect(AppModel.diskSpaceVerdict(freeBytes: 1_000_000_000) == .ok)
            #expect(AppModel.diskSpaceVerdict(freeBytes: nil) == .ok)
        }

        @Test("startRecording refuses below the floor with a clear failure")
        func startRefusesWhenNearlyFull() async {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 100_000_000 }

            model.startRecording(source: .microphone)

            let refused = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(refused)
            if case .failed(let message) = model.phase { #expect(message.contains("200 MB")) }
            #expect(model.liveSource == nil)
            let stoppedRecording = await waitUntil { !model.recordingActive }
            #expect(stoppedRecording)
        }

        @Test("a take refused for space ends its count-in as soon as the answer lands")
        func refusalCutsTheCountInShort() async {
            let model = makeModel()
            model.recordingCountInSeconds = 3
            model.freeDiskSpaceProvider = { 100_000_000 }
            let start = ContinuousClock.now

            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 3)

            let refused = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(refused)
            #expect(start.duration(to: .now) < .seconds(2), "the refusal waited for the count-in")
            #expect(model.recordingCountdown == nil)
            #expect(!model.recordingActive)
        }

        @Test("startRecording below 1 GB warns but still records")
        func startWarnsButRecords() async throws {
            let fixture = try makeSilentWAV()
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

                let model = makeModel()
                model.useStreaming = false
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 500_000_000 }

                model.startRecording(source: .microphone)

                let started = await waitUntil { self.isRecording(model) }
                #expect(started)
                #expect(model.recordingDiskSpaceLow)
                model.cancelCurrentWork()
            }
        }

        @Test("startRecording with plenty of space clears a stale warning")
        func startClearsStaleWarning() async throws {
            let fixture = try makeSilentWAV()
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

                let model = makeModel()
                model.useStreaming = false
                model.recordingDiskSpaceLow = true
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 50_000_000_000 }

                model.startRecording(source: .microphone)

                let startedRecording = await waitUntil { self.isRecording(model) }
                #expect(startedRecording)
                #expect(!model.recordingDiskSpaceLow)
                model.cancelCurrentWork()
            }
        }

        @Test("the free-space query never runs on the main thread, at the start or during a take")
        func queryRunsOffMain() async {
            let model = makeModel()
            let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
            model.freeDiskSpaceProvider = {
                onMain.withLock { $0.append(Thread.isMainThread) }
                return 100_000_000
            }

            model.startRecording(source: .microphone)
            _ = await waitUntil { !model.recordingActive }
            model.installTestTake(source: .microphone)
            await model.checkRecordingDiskSpace()

            #expect(onMain.withLock { $0 } == [false, false])
        }

        @Test("a scratch folder the first take has not made yet is statted through its parent")
        func scratchVolumeBeforeTheFolderExists() {
            let parent = FileManager.default.temporaryDirectory
            let missing = parent.appendingPathComponent("parola-scratch-\(UUID().uuidString)/inflight", isDirectory: true)
            #expect(AppModel.existingAncestor(of: missing).standardizedFileURL.path == parent.standardizedFileURL.path)
            #expect(AppModel.existingAncestor(of: parent).standardizedFileURL.path == parent.standardizedFileURL.path)
        }

        @Test("checkRecordingDiskSpace flips the warning both ways while recording")
        func midRecordingWarnAndClear() async {
            let model = makeModel()
            model.installTestTake(source: .microphone)

            model.freeDiskSpaceProvider = { 500_000_000 }
            await model.checkRecordingDiskSpace()
            #expect(model.recordingDiskSpaceLow)

            model.freeDiskSpaceProvider = { 50_000_000_000 }
            await model.checkRecordingDiskSpace()
            #expect(!model.recordingDiskSpaceLow)
        }

        @Test("checkRecordingDiskSpace does nothing outside a recording")
        func checkIgnoredWhenNotRecording() async {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 0 }

            await model.checkRecordingDiskSpace()

            #expect(model.phase == .idle)
            #expect(!model.recordingDiskSpaceLow)
        }

        @Test("crossing below 200 MB stops the recording gracefully")
        func refuseMidRecordingStops() async throws {
            let fixture = try makeSilentWAV()
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "disk guard fired")
                ))

                let model = makeModel()
                model.useStreaming = false
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 50_000_000_000 }

                model.startRecording(source: .microphone)
                let started = await waitUntil { self.isRecording(model) }
                #expect(started)

                model.freeDiskSpaceProvider = { 100_000_000 }
                await model.checkRecordingDiskSpace()

                let stopped = await waitUntil {
                    if case .failed = model.phase { return true }
                    return false
                }
                #expect(stopped)
                #expect(!isRecording(model))
            }
        }

        @Test("the recording watch runs the disk check on the clock cadence")
        func watchTicksDiskCheck() async {
            let model = makeModel(clock: ImmediateClock())
            model.installTestTake(source: .microphone)
            model.freeDiskSpaceProvider = { 500_000_000 }

            model.startRecordingWatch(checkpoints: false)
            let warned = await waitUntil { model.recordingDiskSpaceLow }
            model.stopRecordingWatch()

            #expect(warned)
            #expect(!model.recordingDiskSpaceLow)
            #expect(model.recordingWatchTask == nil)
        }
    }
}
