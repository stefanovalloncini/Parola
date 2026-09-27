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

    @Test("a second preset of one format adds its name; the first keeps the plain one")
    func secondPresetOfAFormatAddsItsName() {
        var short = ExportSpec.standard(for: .srt)
        short.options.captionLength = .short
        let reels = ExportPreset(name: "SRT short (reels)", spec: short)
        let rules = [AutoExportRule(sourceExtensions: [], presetIDs: [reels.id, srt.id])]
        let jobs = SidecarExportPlanner.plan(
            presets: [srt], rules: rules, library: [reels, srt],
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )
        #expect(jobs.map(\.target.lastPathComponent) == ["clip.srt", "clip.SRT-short-reels.srt"])
        #expect(jobs.map(\.spec) == [srt.spec, short])
        #expect(jobs.allSatisfy { $0.owner == "clip.mov" })
    }

    @Test("two presets with one name and format still get two files")
    func namesakePresets() {
        let first = ExportPreset(name: "Captions", spec: .standard(for: .vtt))
        var wrapped = ExportSpec.standard(for: .vtt)
        wrapped.options.captionLength = .medium
        let second = ExportPreset(name: "Captions", spec: wrapped)
        let third = ExportPreset(name: "Captions", spec: .standard(for: .vtt))
        let jobs = SidecarExportPlanner.plan(presets: [first, second, third], sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"))
        let names = jobs.map(\.target.lastPathComponent)
        #expect(names.count == 3)
        #expect(Set(names).count == 3)
        #expect(names[0] == "a.vtt")
        #expect(names[1] == "a.Captions.vtt")
        #expect(names[2] == "a.Captions-\(third.id.uuidString.prefix(8)).vtt")
    }

    @Test("a preset name with nothing to keep falls back to its format")
    func emptySlug() {
        #expect(SidecarExportPlanner.slug(ExportPreset(name: "(✓)", spec: .standard(for: .txt))) == "txt")
        #expect(SidecarExportPlanner.slug(ExportPreset(name: "  Per speaker / ¶ ", spec: .standard(for: .md))) == "Per-speaker")
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
        let source = SidecarSource(fileExtension: "m4a", folder: folder, baseName: "Standup 10:30 / notes", owner: "entry-1")
        let jobs = SidecarExportPlanner.plan(presets: [txt], source: source)
        #expect(jobs.map(\.target.lastPathComponent) == ["Standup 10-30 - notes.txt"])
        #expect(jobs.allSatisfy { $0.createsDirectory })
    }

    @Test("a folder name never names a folder or a hidden file, and an empty one falls back to Transcript")
    func folderNameIsCleaned() {
        func name(_ raw: String) -> String {
            SidecarSource(fileExtension: "m4a", folder: URL(fileURLWithPath: "/tmp"), baseName: raw, owner: "e").baseName
        }
        #expect(name("  ") == "Transcript")
        #expect(name("a/b/c") == "a-b-c")
        #expect(name("..hidden") == "hidden")
        #expect(name("...") == "Transcript")
        #expect(name("Call 10.30") == "Call 10.30")
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
            spec: srt.spec, target: dir.appendingPathComponent("missing/clip.srt"), owner: "clip.wav"
        )
        let fine = ExportJob(spec: txt.spec, target: dir.appendingPathComponent("clip.txt"), owner: "clip.wav")
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
            presets: [txt], source: SidecarSource(fileExtension: "wav", folder: exports, baseName: "Take", owner: "entry-1")
        )
        let besideJobs = SidecarExportPlanner.plan(
            presets: [txt], sourceURL: dir.appendingPathComponent("ejected/clip.wav")
        )

        let results = await ExportRunner.run(folderJobs + besideJobs, transcript: transcript())

        #expect(results[0].written?.lastPathComponent == "Take.txt")
        #expect(results[1].written == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ejected").path))
    }

    // MARK: - Files already there

    @Test("a file Parola didn't write is kept, and the sidecar lands beside it as a numbered copy")
    func foreignFileIsKept() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloaded = dir.appendingPathComponent("talk.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nOfficial\n".utf8).write(to: downloaded)
        let jobs = SidecarExportPlanner.plan(presets: [srt], sourceURL: dir.appendingPathComponent("talk.mp4"))
        let sink = CapturingDiagnosticsSink()

        let results = await ParolaLog.withSink(sink) { await ExportRunner.run(jobs, transcript: transcript()) }

        #expect(results.first?.written?.lastPathComponent == "talk (2).srt")
        #expect(try String(contentsOf: downloaded, encoding: .utf8).contains("Official"))
        #expect(!OutputMarker.isMarked(downloaded))
        #expect(OutputMarker.owner(of: dir.appendingPathComponent("talk (2).srt")) == "talk.mp4")
        #expect(sink.records.contains {
            $0.level == .notice && $0.message.rendered.hasPrefix("sidecar target holds a file Parola didn't write")
        })
    }

    @Test("a re-run replaces the files it wrote before, numbered copy included")
    func rerunReplacesItsOwnFiles() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("mine".utf8).write(to: dir.appendingPathComponent("talk.txt"))
        let source = dir.appendingPathComponent("talk.mp4")
        let jobs = SidecarExportPlanner.plan(presets: [srt, txt], sourceURL: source)

        let first = await ExportRunner.run(jobs, transcript: transcript())
        let second = await ExportRunner.run(jobs, transcript: transcript())

        #expect(first.map(\.written?.lastPathComponent) == ["talk.srt", "talk (2).txt"])
        #expect(second.map(\.written) == first.map(\.written))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["talk (2).txt", "talk.srt", "talk.txt"])
    }

    @Test("two sources with one stem in one folder keep their own sidecars")
    func sameStemDifferentSources() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fromMov = SidecarExportPlanner.plan(presets: [srt], sourceURL: dir.appendingPathComponent("clip.mov"))
        let fromWav = SidecarExportPlanner.plan(presets: [srt], sourceURL: dir.appendingPathComponent("clip.wav"))

        let mov = await ExportRunner.run(fromMov, transcript: transcript())
        let wav = await ExportRunner.run(fromWav, transcript: transcript())

        #expect(mov.first?.written?.lastPathComponent == "clip.srt")
        #expect(wav.first?.written?.lastPathComponent == "clip (2).srt")
        #expect(OutputMarker.owner(of: dir.appendingPathComponent("clip.srt")) == "clip.mov")
    }

    @Test("two entries with one title write two files in a shared folder")
    func sameTitleDifferentEntries() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = SidecarSource(fileExtension: "m4a", folder: dir, baseName: "Standup", owner: "entry-1")
        let two = SidecarSource(fileExtension: "m4a", folder: dir, baseName: "Standup", owner: "entry-2")

        _ = await ExportRunner.run(SidecarExportPlanner.plan(presets: [txt], source: one), transcript: transcript())
        let second = await ExportRunner.run(SidecarExportPlanner.plan(presets: [txt], source: two), transcript: transcript())

        #expect(second.first?.written?.lastPathComponent == "Standup (2).txt")
    }

    @Test("the marker round-trips its owner and is absent on a plain file")
    func markerRoundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        #expect(OutputMarker.owner(of: file) == nil)
        OutputMarker.mark(file, owner: "clip.mov")
        #expect(OutputMarker.owner(of: file) == "clip.mov")
        #expect(OutputMarker.isMarked(file))
        #expect(OutputMarker.owner(of: dir.appendingPathComponent("absent.txt")) == nil)
    }
}
