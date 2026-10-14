import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("AppModel rule persistence")
@MainActor
struct AppModelRulesTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    private func makeModel(defaults: UserDefaults) throws -> AppModel {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-appmodel-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(libraryURL: tmp, defaults: defaults)
    }

    private func makeReader(defaults: UserDefaults) -> AppModel {
        AppModel(
            libraryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-rules-reader-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults
        )
    }

    @Test("auto-export rules survive a save and reload")
    func autoExportRoundTrip() throws {
        let defaults = freshDefaults()
        let writer = try makeModel(defaults: defaults)
        let rules = [
            AutoExportRule(
                sourceExtensions: ["m4a", "wav"],
                presetIDs: [ExportPreset.builtIn(for: .srt)!.id, ExportPreset.builtIn(for: .txt)!.id]
            ),
            AutoExportRule(
                sourceExtensions: ["mp3"],
                presetIDs: [ExportPreset.builtIn(for: .json)!.id],
                enabled: false
            ),
        ]
        writer.autoExportRules = rules

        let reader = makeReader(defaults: defaults)
        #expect(reader.autoExportRules == rules)
    }

    @Test("a stored rule list from before whole words still loads")
    func oldFindReplaceBlobLoads() throws {
        let defaults = freshDefaults()
        let id = UUID()
        let blob = #"[{"id":"\#(id.uuidString)","find":"cat","replace":"dog","caseSensitive":false,"regex":false,"enabled":true}]"#
        defaults.set(Data(blob.utf8), forKey: "findReplaceRules")

        let reader = makeReader(defaults: defaults)
        #expect(reader.findReplaceRules.map(\.find) == ["cat"])
        #expect(reader.findReplaceRules.first?.wholeWord == false)
    }

    @Test("a whole-word rule survives a save and reload")
    func wholeWordRoundTrip() throws {
        let defaults = freshDefaults()
        let writer = try makeModel(defaults: defaults)
        writer.findReplaceRules = [FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)]

        let reader = makeReader(defaults: defaults)
        #expect(reader.findReplaceRules == writer.findReplaceRules)
        #expect(reader.findReplaceRules.first?.wholeWord == true)
    }

    @Test("ignored-segment rules survive a save and reload")
    func ignoredSegmentRoundTrip() throws {
        let defaults = freshDefaults()
        let writer = try makeModel(defaults: defaults)
        let rules = [
            IgnoredSegmentRule(pattern: "uh"),
            IgnoredSegmentRule(pattern: "[music]", enabled: false),
        ]
        writer.ignoredSegmentRules = rules

        let reader = makeReader(defaults: defaults)
        #expect(reader.ignoredSegmentRules == rules)
    }

    @Test("find-replace rules survive a save and reload")
    func findReplaceRoundTrip() throws {
        let defaults = freshDefaults()
        let writer = try makeModel(defaults: defaults)
        let rules = [
            FindReplaceRule(find: "teh", replace: "the"),
            FindReplaceRule(find: "\\bok\\b", replace: "OK", caseSensitive: true, regex: true, enabled: false),
        ]
        writer.findReplaceRules = rules

        let reader = makeReader(defaults: defaults)
        #expect(reader.findReplaceRules == rules)
    }

    @Test("a fresh model with no stored rules starts empty")
    func defaultsAreEmpty() throws {
        let model = try makeModel(defaults: freshDefaults())
        #expect(model.autoExportRules.isEmpty)
        #expect(model.ignoredSegmentRules.isEmpty)
        #expect(model.findReplaceRules.isEmpty)
    }

    @Test("a landed transcript gets the user's rules, then the Italian orthography")
    func coordinatorAppliesRulesThenOrthography() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "ehm")]
        model.findReplaceRules = [FindReplaceRule(find: "perchè", replace: "per quale motivo")]
        let input = Transcript(
            segments: ["ehm", "perchè no", "un pò"].enumerated().map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: $1)
            },
            language: "it",
            modelName: "openai_whisper-tiny"
        )

        let out = await model.coordinator.postProcessed(input)

        #expect(out.segments.map(\.text) == ["per quale motivo no", "un po'"])
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
    }

    private func makeAudioFile(ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-autoexport-\(UUID().uuidString).\(ext)")
        try Data("audio".utf8).write(to: url)
        return url
    }

    @Test("runAutoExports writes the planned presets for a matching rule")
    func runAutoExportsWritesFiles() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(
                sourceExtensions: ["m4a"],
                presetIDs: [ExportPreset.builtIn(for: .srt)!.id, ExportPreset.builtIn(for: .txt)!.id]
            ),
        ]
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("hello there"), audioSource: audio)

        model.runAutoExports(for: entry)

        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        let base = entry.title
        let srt = exportsDir.appendingPathComponent("\(base).srt")
        let txt = exportsDir.appendingPathComponent("\(base).txt")

        try await pollUntil {
            FileManager.default.fileExists(atPath: srt.path)
                && FileManager.default.fileExists(atPath: txt.path)
        }
        #expect(FileManager.default.fileExists(atPath: srt.path))
        #expect(FileManager.default.fileExists(atPath: txt.path))

        let txtContents = try String(contentsOf: txt, encoding: .utf8)
        #expect(txtContents.contains("hello there"))
    }

    @Test("two imports of files with the same name both keep their exports, dots and all")
    func sameNamedImportsKeepBothExports() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(
                sourceExtensions: ["m4a"],
                presetIDs: [ExportPreset.builtIn(for: .srt)!.id, ExportPreset.builtIn(for: .txt)!.id]
            ),
        ]
        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        var entries: [LibraryEntry] = []
        for text in ["first call", "second call"] {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-autoexport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent("Call 10.30.m4a")
            try Data("audio".utf8).write(to: audio)
            let entry = try await model.library.add(transcript: transcript(text), audioSource: audio, source: .file)
            #expect(entry.title == "Call 10.30")
            model.runAutoExports(for: entry)
            let expected = entries.isEmpty ? "Call 10.30" : "Call 10.30 (2)"
            try await pollUntil {
                ["srt", "txt"].allSatisfy {
                    FileManager.default.fileExists(atPath: exportsDir.appendingPathComponent("\(expected).\($0)").path)
                }
            }
            entries.append(entry)
        }

        let first = try String(contentsOf: exportsDir.appendingPathComponent("Call 10.30.txt"), encoding: .utf8)
        let second = try String(contentsOf: exportsDir.appendingPathComponent("Call 10.30 (2).txt"), encoding: .utf8)
        #expect(first.contains("first call"))
        #expect(second.contains("second call"))
        #expect(!FileManager.default.fileExists(atPath: exportsDir.appendingPathComponent("Call 10.srt").path))
    }

    @Test("an export name is taken when any of the import's formats already uses it")
    func oneImportsFormatsShareOneName() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(
                sourceExtensions: ["m4a"],
                presetIDs: [ExportPreset.builtIn(for: .srt)!.id, ExportPreset.builtIn(for: .txt)!.id]
            ),
        ]
        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: exportsDir.appendingPathComponent("Talk.txt"))
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("one name"), audioSource: audio, title: "Talk")

        model.runAutoExports(for: entry)

        try await pollUntil {
            ["srt", "txt"].allSatisfy {
                OutputMarker.owner(of: exportsDir.appendingPathComponent("Talk (2).\($0)")) == entry.id
            }
        }
        #expect(!FileManager.default.fileExists(atPath: exportsDir.appendingPathComponent("Talk.srt").path))
        #expect(try String(contentsOf: exportsDir.appendingPathComponent("Talk.txt"), encoding: .utf8) == "someone else's")
    }

    @Test("running an entry's rules again replaces its own exports instead of numbering them")
    func rerunReplacesItsOwnExports() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["m4a"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id]),
        ]
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("run twice"), audioSource: audio, title: "Talk")
        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        let target = exportsDir.appendingPathComponent("Talk.txt")

        model.runAutoExports(for: entry)
        try await pollUntil { OutputMarker.owner(of: target) == entry.id }
        try await model.library.updateTranscript(transcript("the second run's words"), for: entry.id)
        model.runAutoExports(for: entry)
        try await pollUntil {
            (try? String(contentsOf: target, encoding: .utf8))?.contains("the second run's words") == true
        }

        #expect(try String(contentsOf: target, encoding: .utf8).contains("the second run's words"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: exportsDir.path) == ["Talk.txt"])
    }

    @Test("a title with a slash exports into Exports, not a folder of its own")
    func slashInTitleStaysInExports() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["m4a"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id]),
        ]
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("slash title"), audioSource: audio, title: "Q3/Q4 review")

        model.runAutoExports(for: entry)

        let target = model.library.libraryURL.appendingPathComponent("Exports/Q3-Q4 review.txt")
        try await pollUntil { FileManager.default.fileExists(atPath: target.path) }
        #expect(try String(contentsOf: target, encoding: .utf8).contains("slash title"))
    }

    @Test("runAutoExports writes nothing when no rule matches the source extension")
    func runAutoExportsSkipsUnmatched() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .srt)!.id]),
        ]
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("hi"), audioSource: audio)

        model.runAutoExports(for: entry)

        try await Task.sleep(for: .milliseconds(200))
        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: exportsDir.path) == false)
    }

    @Test("runAutoExports ignores a disabled rule")
    func runAutoExportsIgnoresDisabled() async throws {
        let model = try makeModel(defaults: freshDefaults())
        model.autoExportRules = [
            AutoExportRule(
                sourceExtensions: ["m4a"],
                presetIDs: [ExportPreset.builtIn(for: .srt)!.id],
                enabled: false
            ),
        ]
        let audio = try makeAudioFile(ext: "m4a")
        let entry = try await model.library.add(transcript: transcript("hi"), audioSource: audio)

        model.runAutoExports(for: entry)

        try await Task.sleep(for: .milliseconds(200))
        let exportsDir = model.library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: exportsDir.path) == false)
    }
}
