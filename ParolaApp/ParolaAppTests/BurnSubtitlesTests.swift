import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Burn subtitles")
struct BurnSubtitlesTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
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

    // MARK: - Bridge

    @Test("the bridge reports a burn's state, progress and output")
    func bridgeBurnState() {
        let output = URL(fileURLWithPath: "/tmp/clip (captioned).mp4")
        #expect(ParolaAutomationServer.burnState(nil) == .null)
        #expect(ParolaAutomationServer.burnState(BurnJob(id: UUID(), output: output, state: .running(progress: 0.4))) == .object([
            "state": .string("running"), "progress": .double(0.4), "output": .string(output.path),
        ]))
        #expect(ParolaAutomationServer.burnState(BurnJob(id: UUID(), output: output, state: .failed(message: "boom"))) == .object([
            "state": .string("failed"), "message": .string("boom"), "output": .string(output.path),
        ]))
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

    private func startBurn(
        _ model: AppModel, picker: TestFilePicker, output: String = "out.mp4",
        operation: @escaping @Sendable (Transcript, URL, URL, SubtitleBurner.Style, @escaping @Sendable (Double) -> Void) async throws -> Void
    ) async {
        let dir = FileManager.default.temporaryDirectory
        await picker.queueInputResponse([dir.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(dir.appendingPathComponent(output))
        model.burnOperation = operation
        model.burnSubtitlesIntoVideo()
    }

    @Test("a burn reports its progress in its own job and leaves the phase alone")
    func burnReportsProgressAndFinishes() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(100))
            progress(1.0)
        }

        await Self.waitUntil { model.burnJob?.state == .running(progress: 0.5) }
        #expect(model.burnJob?.state == .running(progress: 0.5))
        #expect(model.phase == .ready)
        #expect(model.canCancel)

        await Self.waitUntil { model.burnJob?.state == .finished }
        #expect(model.burnJob?.state == .finished)
        #expect(model.burnJob?.output.lastPathComponent == "out.mp4")
        #expect(model.phase == .ready)
        #expect(model.canCancel == false)

        model.dismissBurnJob()
        #expect(model.burnJob == nil)
    }

    @Test("a progress report that lands after the burn ended doesn't bring it back")
    func lateProgressIsIgnored() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        let late = LateProgress()

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            await late.keep(progress)
        }
        await Self.waitUntil { model.burnJob?.state == .finished }

        await late.fire(0.3)
        await settle()
        #expect(model.burnJob?.state == .finished)
    }

    @Test("with only a burn running, Cancel stops it and the transcript stays open")
    func cancelStopsBurn() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }
        await Self.waitUntil { model.burnIsRunning }
        #expect(model.canCancel)

        model.cancelCurrentWork()

        await Self.waitUntil { model.burnJob == nil && !model.canCancel }
        #expect(model.phase == .ready)
        #expect(model.burnJob == nil)
        #expect(model.canCancel == false)
    }

    @Test("Cancel for a run in the window leaves a burn behind it running")
    func cancelLeavesABackgroundBurn() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }
        await Self.waitUntil { model.burnIsRunning }
        model.batchTask = Task { try? await Task.sleep(for: .seconds(60)) }

        model.cancelCurrentWork()
        await settle()

        #expect(model.burnIsRunning)
        #expect(model.canCancel)

        model.cancelBurn()
        await Self.waitUntil { model.burnJob == nil }
        #expect(model.burnJob == nil)
    }

    @Test("a burn holds back no arrival, download or open")
    func burnBlocksNothing() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }
        await Self.waitUntil { model.burnIsRunning }

        #expect(!model.phaseDefersArrivals)
        #expect(model.downloadBlockedReason == nil)
        #expect(model.entryOpenRefusal == nil)
        model.cancelBurn()
    }

    @Test("dismissing the save panel abandons the burn without starting a job")
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

        await Self.waitUntil { !model.canCancel }
        #expect(model.phase == .ready)
        #expect(model.burnJob == nil)
        #expect(model.canCancel == false)
    }

    @Test("a failed burn says so in its strip and leaves the open transcript on screen")
    func failedBurnReportsInItsJob() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        await startBurn(model, picker: picker) { _, _, _, _, _ in
            throw ParolaError.ioError("boom")
        }

        await Self.waitUntil {
            if case .failed = model.burnJob?.state { return true }
            return false
        }
        guard case .failed(let message) = model.burnJob?.state else {
            Issue.record("expected a failed burn, got \(String(describing: model.burnJob))")
            return
        }
        #expect(message.contains("boom"))
        #expect(model.phase == .ready)
        #expect(model.transcript != nil)
    }

    @Test("a second burn can't start while one runs")
    func oneBurnAtATime() async {
        let picker = TestFilePicker()
        let model = makeModel(filePicker: picker)
        model.transcript = Self.makeTranscript()

        await startBurn(model, picker: picker) { _, _, _, _, progress in
            progress(0.25)
            try await Task.sleep(for: .seconds(60))
        }
        await Self.waitUntil { model.burnIsRunning }

        model.requestBurnSubtitles()
        #expect(model.burnSheetOpen == false)
        model.cancelBurn()
    }
}

private actor LateProgress {
    private var report: (@Sendable (Double) -> Void)?

    func keep(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func fire(_ value: Double) {
        report?(value)
    }
}
