import Foundation
import Testing
@testable import ParolaCore

@Suite("Sidecar export planner and runner", .tags(.fileSystem))
struct SidecarExportTests {
    private let srt = ExportPreset.builtIn(for: .srt)!
    private let txt = ExportPreset.builtIn(for: .txt)!
    private let md = ExportPreset.builtIn(for: .md)!

    private func transcript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1.2, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.2, end: 2.4, text: "From Parola."),
            ],
            language: "en",
            modelName: "test",
            durationSeconds: 2.4
        )
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("presets named directly come first, then the rules' presets, each preset once")
    func namedPresetsThenRules() {
        let rules = [AutoExportRule(sourceExtensions: ["wav"], presetIDs: [txt.id, md.id])]
        let jobs = SidecarExportPlanner.plan(
            presets: [srt, txt], rules: rules, library: ExportPreset.builtIns,
            sourceURL: URL(fileURLWithPath: "/Users/me/Talks/clip.wav")
        )
        #expect(jobs.map(\.target.path) == [
            "/Users/me/Talks/clip.srt", "/Users/me/Talks/clip.txt", "/Users/me/Talks/clip.md",
        ])
        #expect(jobs.allSatisfy { !$0.createsDirectory })
    }

    @Test("two presets that land on one file write it once, the first one's way")
    func sharedTargetWrittenOnce() {
        var short = ExportSpec.standard(for: .srt)
        short.options.captionLength = .short
        let reels = ExportPreset(name: "SRT short (reels)", spec: short)
        let rules = [AutoExportRule(sourceExtensions: [], presetIDs: [reels.id])]
        let jobs = SidecarExportPlanner.plan(
            presets: [srt], rules: rules, library: [reels],
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )
        #expect(jobs.map(\.target.lastPathComponent) == ["clip.srt"])
        #expect(jobs.first?.spec == srt.spec)
    }

    @Test("a rule that doesn't match the source's extension adds nothing")
    func unmatchedRule() {
        let rules = [AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [txt.id])]
        let jobs = SidecarExportPlanner.plan(
            presets: [], rules: rules, library: ExportPreset.builtIns,
            sourceURL: URL(fileURLWithPath: "/tmp/clip.wav")
        )
        #expect(jobs.isEmpty)
    }

    @Test("a folder source writes under its own name, with slashes and colons made safe")
    func folderSource() {
        let folder = URL(fileURLWithPath: "/Users/me/Exports", isDirectory: true)
        let source = SidecarSource(fileExtension: "m4a", folder: folder, baseName: "Standup 10:30 / notes")
        let jobs = SidecarExportPlanner.plan(presets: [txt], source: source)
        #expect(jobs.map(\.target.lastPathComponent) == ["Standup 10-30 - notes.txt"])
        #expect(jobs.allSatisfy { $0.createsDirectory })
    }

    @Test("an empty name falls back to Transcript")
    func emptyFolderName() {
        let source = SidecarSource(fileExtension: "m4a", folder: URL(fileURLWithPath: "/tmp"), baseName: "  ")
        #expect(source.baseName == "Transcript")
    }

    @Test("the runner writes every job and reports where each landed")
    func runnerWritesEveryJob() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = SidecarExportPlanner.plan(presets: [srt, txt], sourceURL: dir.appendingPathComponent("clip.wav"))

        let results = await ExportRunner.run(jobs, transcript: transcript())

        #expect(results.map(\.written?.lastPathComponent) == ["clip.srt", "clip.txt"])
        #expect(results.allSatisfy { $0.error == nil })
        let text = try String(contentsOf: dir.appendingPathComponent("clip.txt"), encoding: .utf8)
        #expect(text.contains("Hello world."))
    }

    @Test("a failed job is logged and the rest still land")
    func failureIsLoggedAndTheRestLand() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unwritable = ExportJob(
            spec: srt.spec, target: dir.appendingPathComponent("missing/clip.srt")
        )
        let fine = ExportJob(spec: txt.spec, target: dir.appendingPathComponent("clip.txt"))
        let sink = CapturingDiagnosticsSink()

        let results = await ParolaLog.withSink(sink) {
            await ExportRunner.run([unwritable, fine], transcript: transcript())
        }

        #expect(results[0].written == nil)
        #expect(results[0].error != nil)
        #expect(results[1].written == fine.target)
        let failures = sink.records.filter { $0.message.rendered == "sidecar export failed as srt" }
        #expect(failures.count == 1)
        #expect(failures.first?.level == .error)
        #expect(failures.first?.formattedLine.contains("missing") == false)
    }

    @Test("a folder job creates its folder; a source's vanished folder is not recreated")
    func folderCreation() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exports = dir.appendingPathComponent("Parola Exports", isDirectory: true)
        let folderJobs = SidecarExportPlanner.plan(
            presets: [txt], source: SidecarSource(fileExtension: "wav", folder: exports, baseName: "Take")
        )
        let besideJobs = SidecarExportPlanner.plan(
            presets: [txt], sourceURL: dir.appendingPathComponent("ejected/clip.wav")
        )

        let results = await ExportRunner.run(folderJobs + besideJobs, transcript: transcript())

        #expect(results[0].written?.lastPathComponent == "Take.txt")
        #expect(results[1].written == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ejected").path))
    }
}
