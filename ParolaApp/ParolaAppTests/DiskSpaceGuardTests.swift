import Foundation
import Testing
@testable import Parola
import ParolaCore

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
        func startRefusesWhenNearlyFull() {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 100_000_000 }

            model.startRecording(source: .microphone)

            guard case .failed(let message) = model.phase else {
                Issue.record("expected .failed, got \(model.phase)")
                return
            }
            #expect(message.contains("200 MB"))
            #expect(model.liveSource == nil)
        }

        @Test("startRecording below 1 GB warns but still records")
        func startWarnsButRecords() async throws {
            let fixture = try makeSilentWAV()
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
            defer { Task { await MockAudioSourceRegistry.shared.clear() } }

            let model = makeModel()
            model.useStreaming = false
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 500_000_000 }

            model.startRecording(source: .microphone)

            #expect(model.recordingDiskSpaceLow)
            let started = await waitUntil { self.isRecording(model) }
            #expect(started)
            model.cancelCurrentWork()
        }

        @Test("startRecording with plenty of space clears a stale warning")
        func startClearsStaleWarning() {
            let model = makeModel()
            model.recordingDiskSpaceLow = true
            model.recordingCountInSeconds = 3
            model.freeDiskSpaceProvider = { 50_000_000_000 }

            model.startRecording(source: .microphone)

            #expect(!model.recordingDiskSpaceLow)
            model.cancelRecordingCountdown()
        }

        @Test("checkRecordingDiskSpace flips the warning both ways while recording")
        func midRecordingWarnAndClear() {
            let model = makeModel()
            model.phase = .recording(source: .microphone)

            model.freeDiskSpaceProvider = { 500_000_000 }
            model.checkRecordingDiskSpace()
            #expect(model.recordingDiskSpaceLow)

            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.checkRecordingDiskSpace()
            #expect(!model.recordingDiskSpaceLow)
        }

        @Test("checkRecordingDiskSpace does nothing outside a recording")
        func checkIgnoredWhenNotRecording() {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 0 }

            model.checkRecordingDiskSpace()

            #expect(model.phase == .idle)
            #expect(!model.recordingDiskSpaceLow)
        }

        @Test("crossing below 200 MB stops the recording gracefully")
        func refuseMidRecordingStops() async throws {
            let fixture = try makeSilentWAV()
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                failure: MockTranscriberFailure(code: .transcriptionFailed, message: "disk guard fired")
            ))
            defer {
                Task {
                    await MockAudioSourceRegistry.shared.clear()
                    await MockTranscriberRegistry.shared.clear()
                }
            }

            let model = makeModel()
            model.useStreaming = false
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }

            model.startRecording(source: .microphone)
            let started = await waitUntil { self.isRecording(model) }
            #expect(started)

            model.freeDiskSpaceProvider = { 100_000_000 }
            model.checkRecordingDiskSpace()

            let stopped = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(stopped)
            #expect(!isRecording(model))
        }

        @Test("the recording watch runs the disk check on the clock cadence")
        func watchTicksDiskCheck() async {
            let model = makeModel(clock: ImmediateClock())
            model.phase = .recording(source: .microphone)
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
