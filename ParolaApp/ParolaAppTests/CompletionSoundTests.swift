import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Completion sound", .serialized)
struct CompletionSoundTests {

    @MainActor
    private final class SoundCounter {
        var plays = 0
    }

    private func makeRig(_ label: String, defaults: UserDefaults = temporaryDefaults()) async -> (model: AppModel, sound: SoundCounter) {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL(label))
        // A startup scan still reading when a landing saves would put its empty list back over the landed row.
        await awaitGuarded("the model's startup library scan") { await model.libraryRefreshTask?.value }
        let counter = SoundCounter()
        model.completionSoundPlayer = { counter.plays += 1 }
        model.playSoundWhenFinished = true
        return (model, counter)
    }

    private func makeTranscript(_ text: String = "done") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("a finished transcription plays the sound once")
    func finishedTranscriptionPlaysOnce() async {
        let (model, sound) = await makeRig("sound-one")

        model.land(RunLanding(kind: .file, transcript: makeTranscript()))

        await awaitGuarded("the landing's steps") { await model.awaitLandingSteps() }
        #expect(model.libraryEntries.count == 1)
        #expect(sound.plays == 1)
    }

    @Test("a take saved without taking the selection stays silent")
    func inactiveSaveIsSilent() async {
        let (model, sound) = await makeRig("sound-inactive")

        model.land(RunLanding(kind: .salvagedTake, transcript: makeTranscript()))

        await awaitGuarded("the landing's steps") { await model.awaitLandingSteps() }
        #expect(model.libraryEntries.count == 1)
        #expect(sound.plays == 0)
    }

    @Test("with the setting off nothing plays")
    func settingOffIsSilent() async {
        let (model, sound) = await makeRig("sound-off")
        model.playSoundWhenFinished = false

        model.land(RunLanding(kind: .file, transcript: makeTranscript()))

        await awaitGuarded("the landing's steps") { await model.awaitLandingSteps() }
        #expect(model.libraryEntries.count == 1)
        #expect(sound.plays == 0)
    }

    @Test("a batch of three plays once, at the end")
    func batchPlaysOnceAtTheEnd() async throws {
        let (model, sound) = await makeRig("sound-batch")
        model.batchExportPresetIDs = []
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionSoundTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var jobs: [BatchJob] = []
        for name in ["one", "two", "three"] {
            let url = scratch.appendingPathComponent("\(name).wav")
            try Data("fake".utf8).write(to: url)
            jobs.append(BatchJob(url: url, status: .transcribing))
        }
        model.batchJobs = jobs

        for job in jobs {
            await model.handleBatchEvent(.completed(jobID: job.id, transcript: makeTranscript(job.url.lastPathComponent)))
        }
        #expect(sound.plays == 0)

        await model.handleBatchEvent(.finished)

        #expect(sound.plays == 1)
        model.clearBatch()
    }

    @Test("a batch that ends with a failure still rings once for the run")
    func batchRingsWhateverTheOutcomeMix() async throws {
        let (model, sound) = await makeRig("sound-batch-mixed")
        model.batchExportPresetIDs = []
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionSoundTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let good = scratch.appendingPathComponent("good.wav")
        let bad = scratch.appendingPathComponent("bad.wav")
        try Data("fake".utf8).write(to: good)
        try Data("fake".utf8).write(to: bad)
        let goodJob = BatchJob(url: good, status: .transcribing)
        let badJob = BatchJob(url: bad, status: .transcribing)
        model.batchJobs = [goodJob, badJob]

        await model.handleBatchEvent(.completed(jobID: goodJob.id, transcript: makeTranscript()))
        await model.handleBatchEvent(.failed(jobID: badJob.id, reason: "boom"))
        await model.handleBatchEvent(.finished)

        #expect(sound.plays == 1)
        model.clearBatch()
    }

    @Test("a leftover done job from an earlier batch does not ring for a later one")
    func leftoverDoneJobDoesNotRingTwice() async {
        let (model, sound) = await makeRig("sound-batch-leftover")
        let leftover = BatchJob(url: URL(fileURLWithPath: "/tmp/CompletionSoundTests/old.wav"), status: .done)
        let failed = BatchJob(url: URL(fileURLWithPath: "/tmp/CompletionSoundTests/new.wav"), status: .failed)
        model.batchJobs = [leftover, failed]

        await model.handleBatchEvent(.finished)
        #expect(sound.plays == 1)

        // The same leftover is still sitting there; a second run's finish rings once more, not twice.
        await model.handleBatchEvent(.finished)
        #expect(sound.plays == 2)
        model.clearBatch()
    }

    @Test("a run the user cancelled stays quiet")
    func cancelledRunIsSilent() async {
        let (model, sound) = await makeRig("sound-batch-cancelled")
        let job = BatchJob(url: URL(fileURLWithPath: "/tmp/CompletionSoundTests/cancel.wav"), status: .transcribing)
        model.batchJobs = [job]

        model.cancelAllInFlightBatchJobs()
        await model.handleBatchEvent(.finished)

        #expect(sound.plays == 0)
        model.clearBatch()
    }

    @Test("importing subtitles is not a transcription and stays quiet")
    func subtitleImportIsSilent() async throws {
        let (model, sound) = await makeRig("sound-subtitles")
        let srt = FileManager.default.temporaryDirectory
            .appendingPathComponent("completion-sound-\(UUID().uuidString).srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nimported line\n".write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }

        model.importSubtitle(fileURL: srt)

        await awaitGuarded("the import's landing") { await model.awaitLandingSteps() }
        #expect(model.libraryEntries.count == 1)
        #expect(sound.plays == 0)
    }

    @Test("a batch wave that still has pending jobs holds the sound")
    func partialWaveIsSilent() async {
        let (model, sound) = await makeRig("sound-batch-partial")
        let done = BatchJob(url: URL(fileURLWithPath: "/tmp/CompletionSoundTests/done.wav"), status: .done)
        let pending = BatchJob(url: URL(fileURLWithPath: "/tmp/CompletionSoundTests/pending.wav"), status: .pending)
        model.batchJobs = [done, pending]

        await model.handleBatchEvent(.finished)

        #expect(sound.plays == 0)
        model.clearBatch()
    }

    @Test("the setting is read at bootstrap and again on reload")
    func settingLoadsAtBootstrapAndOnReload() {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "playSoundWhenFinished")

        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("sound-bootstrap"))
        #expect(model.playSoundWhenFinished)

        defaults.set(false, forKey: "playSoundWhenFinished")
        model.reloadSettings()

        #expect(model.playSoundWhenFinished == false)
    }

    @Test("the toggle writes the key the bridge and the General pane share")
    func togglePersistsUnderTheSharedKey() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("sound-key"))

        model.playSoundWhenFinished = true

        #expect(defaults.bool(forKey: "playSoundWhenFinished"))
        #expect(ParolaAutomationServer.writableSettingKeys.contains("playSoundWhenFinished"))
        #expect(SettingsPaneScope.general.defaultsKeys.contains("playSoundWhenFinished"))
    }
}
