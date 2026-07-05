import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Burn subtitles")
struct BurnSubtitlesTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        filePicker: FilePicker? = nil
    ) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: defaults ?? makeIsolatedDefaults(),
            filePicker: filePicker ?? TestFilePicker(),
            libraryURL: makeTempLibraryURL("burn")
        )
    }

    private static func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "stub"
        )
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Phase

    @Test("exporting phase compares on progress")
    func exportingEquality() {
        #expect(AppModel.Phase.exporting(progress: 0.5) == .exporting(progress: 0.5))
        #expect(AppModel.Phase.exporting(progress: 0.5) != .exporting(progress: 0.6))
        #expect(AppModel.Phase.exporting(progress: 0) != .idle)
    }

    @Test("the bridge serializes the exporting phase with its progress")
    func bridgePhaseSerialization() {
        let phase = AppModel.Phase.exporting(progress: 0.4)
        #expect(ParolaAutomationServer.phaseName(phase) == "exporting")
        #expect(ParolaAutomationServer.phaseDetail(phase) == .object(["progress": .double(0.4)]))
    }

    // MARK: - Style mapping

    @Test("font sizes map small, medium, large to real point sizes")
    func fontSizePoints() {
        #expect(BurnFontSize.small.pointSize == 22)
        #expect(BurnFontSize.medium.pointSize == 28)
        #expect(BurnFontSize.large.pointSize == 36)
    }

    @Test("the style factory maps choices onto SubtitleBurner.Style without inventing fields")
    func styleMapping() {
        let styled = SubtitleBurner.Style.make(fontSize: .large, textColor: .yellow, outline: false)
        #expect(styled.fontSize == 36)
        #expect(styled.textColor.components?.first == 1)
        #expect((styled.textColor.components?[2] ?? 1) < 0.5)
        #expect(styled.strokeWidth == 0)

        let defaults = SubtitleBurner.Style.make(fontSize: .medium, textColor: .white, outline: true)
        let stock = SubtitleBurner.Style()
        #expect(defaults.fontSize == stock.fontSize)
        #expect(defaults.fontName == stock.fontName)
        #expect(defaults.bottomInset == stock.bottomInset)
        #expect(defaults.strokeWidth == stock.strokeWidth)
    }

    @Test("burn style choices persist to defaults and reload")
    func styleChoicesRoundTrip() {
        let defaults = makeIsolatedDefaults()
        let model = makeModel(defaults: defaults)

        model.burnFontSizeRaw = BurnFontSize.large.rawValue
        model.burnTextColorRaw = BurnTextColor.yellow.rawValue
        model.burnOutline = false

        #expect(defaults.string(forKey: "burnFontSize") == "large")
        #expect(defaults.string(forKey: "burnTextColor") == "yellow")
        #expect(defaults.bool(forKey: "burnOutline") == false)

        let fresh = makeModel(defaults: defaults)
        #expect(fresh.burnFontSize == .large)
        #expect(fresh.burnTextColor == .yellow)
        #expect(fresh.burnOutline == false)
    }

    // MARK: - Flow

    @Test("requestBurnSubtitles opens the style sheet only with a transcript")
    func requestOpensSheet() {
        let model = makeModel()
        model.requestBurnSubtitles()
        #expect(model.burnSheetOpen == false)

        model.transcript = Self.makeTranscript()
        model.requestBurnSubtitles()
        #expect(model.burnSheetOpen)
    }

    @Test("a burn drives the phase to exporting with progress and back to ready")
    func burnReportsProgressAndFinishes() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(50))
            progress(1.0)
        }

        model.burnSubtitlesIntoVideo()

        await Self.waitUntil { model.phase == .exporting(progress: 0.5) }
        #expect(model.phase == .exporting(progress: 0.5))
        #expect(model.canCancel)

        await Self.waitUntil { model.phase == .ready }
        #expect(model.phase == .ready)
        #expect(model.canCancel == false)
    }

    @Test("cancelCurrentWork stops a burn and returns to the loaded transcript")
    func cancelStopsBurn() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }

        model.burnSubtitlesIntoVideo()
        await Self.waitUntil { model.canCancel }
        #expect(model.canCancel)

        model.cancelCurrentWork()

        await Self.waitUntil { model.phase == .ready && !model.canCancel }
        #expect(model.phase == .ready)
        #expect(model.canCancel == false)
    }

    @Test("deferred arrivals drain into the batch when a burn finishes")
    func finishedBurnDrainsDeferredArrivals() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .milliseconds(200))
        }

        model.burnSubtitlesIntoVideo()
        await Self.waitUntil { model.phase == .exporting(progress: 0.25) }

        let url = URL(fileURLWithPath: "/tmp/mid-burn.wav")
        model.transcribe(fileURL: url)
        #expect(model.deferredArrivals == [url])
        #expect(model.batchJobs.isEmpty)

        await Self.waitUntil { model.batchJobs.contains { $0.url == url } }
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.contains { $0.url == url })
    }

    @Test("a failed burn still drains deferred arrivals")
    func failedBurnDrainsDeferredArrivals() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .milliseconds(200))
            throw ParolaError.ioError("boom")
        }

        model.burnSubtitlesIntoVideo()
        await Self.waitUntil { model.phase == .exporting(progress: 0.25) }

        let url = URL(fileURLWithPath: "/tmp/mid-burn-fail.wav")
        model.transcribe(fileURL: url)
        #expect(model.deferredArrivals == [url])

        await Self.waitUntil { model.batchJobs.contains { $0.url == url } }
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.contains { $0.url == url })
    }

    @Test("cancelling a burn discards deferred arrivals")
    func cancelledBurnDiscardsDeferredArrivals() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }

        model.burnSubtitlesIntoVideo()
        await Self.waitUntil { model.phase == .exporting(progress: 0.25) }

        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/mid-burn-cancel.wav"))
        #expect(model.deferredArrivals.count == 1)

        model.cancelCurrentWork()

        await Self.waitUntil { model.phase == .ready && !model.canCancel }
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.isEmpty)
    }

    @Test("dismissing the save panel abandons the burn without touching the phase")
    func abandonedSavePanelLeavesPhase() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        await picker.queueInputResponse([FileManager.default.temporaryDirectory.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(nil)

        model.burnOperation = { _, _, _, _, _ in
            Issue.record("burn must not start without a destination")
        }

        model.burnSubtitlesIntoVideo()

        await Self.waitUntil { !model.canCancel && model.phase == .ready }
        #expect(model.phase == .ready)
        #expect(model.canCancel == false)
    }

    @Test("a failed burn surfaces the failure message")
    func failedBurnSetsFailedPhase() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent("out.mp4"))

        model.burnOperation = { _, _, _, _, _ in
            throw ParolaError.ioError("boom")
        }

        model.burnSubtitlesIntoVideo()

        await Self.waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("boom"))
    }
}
