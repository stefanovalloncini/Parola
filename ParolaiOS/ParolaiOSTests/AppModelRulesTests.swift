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
        let base = (entry.title as NSString).deletingPathExtension
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

    private func pollUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
