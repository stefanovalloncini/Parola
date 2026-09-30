import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private let exportFailureDomain = "parola-export-logging"

@MainActor
@Suite("Export logging", .serialized)
struct ExportLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func exportRecords(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == .export && $0.message.rendered == message }
    }

    private func waitForRecord(
        _ sink: CapturingDiagnosticsSink, message: String
    ) async -> LogRecord? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let record = exportRecords(sink, message: message).first { return record }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func makeModel(filePicker: FilePicker? = nil) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults("test-export-logging-"),
            filePicker: filePicker ?? TestFilePicker(),
            libraryURL: makeTempLibraryURL("export-logging")
        )
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "stub"
        )
    }

    /// A destination whose parent folder does not exist, so the write throws without a real disk fault.
    private func unwritableDestination(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-export-logging-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test("an export that cannot be written names the format, not the destination")
    func exportFailure() async throws {
        try await withSink { sink in
            let picker = TestFilePicker()
            let model = makeModel(filePicker: picker)
            model.transcript = makeTranscript()
            let destination = unwritableDestination("secret-notes.txt")
            await picker.queueSaveResponse(destination)

            model.performExport(.standard(for: .txt))

            let record = try #require(await waitForRecord(sink, message: "export failed as txt"))
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("secret-notes") == false)
            #expect(record.formattedLine.contains("/") == false)
        }
    }

    @Test("a failed burn is logged with its error and how long it ran")
    func burnFailure() async throws {
        try await withSink { sink in
            let picker = TestFilePicker()
            let model = makeModel(filePicker: picker)
            model.transcript = makeTranscript()
            model.phase = .ready
            let directory = FileManager.default.temporaryDirectory
            await picker.queueInputResponse([directory.appendingPathComponent("in.mp4")])
            await picker.queueSaveResponse(directory.appendingPathComponent("out.mp4"))
            model.burnOperation = { _, _, _, _, _ in
                throw NSError(domain: exportFailureDomain, code: 7)
            }

            model.burnSubtitlesIntoVideo()

            let record = try #require(await waitForRecord(sink, message: "burn failed"))
            #expect(record.level == .error)
            #expect(record.fields[.error]?.text == "\(exportFailureDomain).7")
            #expect(record.fields[.elapsed] != nil)
        }
    }

    @Test("a document save that throws is logged without the destination")
    func documentSaveFailure() async throws {
        try await withSink { sink in
            let picker = TestFilePicker()
            let model = makeModel(filePicker: picker)
            model.transcript = makeTranscript()
            model.sourceFileURL = URL(fileURLWithPath: "/tmp/parola-export-logging-source.wav")
            await picker.queueSaveResponse(unwritableDestination("secret-notes.parola"))

            model.saveProjectDocument()

            let record = try #require(await waitForRecord(sink, message: "document save failed"))
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("secret-notes") == false)
        }
    }

    // .logFacade: auto-export runs detached, and a detached task logs to the installed sink, not a scope.
    @Test("an auto-export failure is no longer silent", .logFacade)
    func autoExportFailure() async throws {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }

        let model = makeModel()
        model.sweptFolders = { [] }
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])
        ]

        model.runAutoExports(
            transcript: makeTranscript(),
            audioSource: unwritableDestination("secret-notes.wav"),
            source: .file,
            entry: nil
        )

        let record = try #require(await waitForRecord(sink, message: "sidecar export failed as txt"))
        #expect(record.level == .error)
        #expect(record.fields[.error] != nil)
        #expect(record.formattedLine.contains("secret-notes") == false)
    }

    // The bulk library export runs an NSOpenPanel modally, so its catch is pinned in source.
    private func appSource(_ name: String) throws -> String {
        try flattened(appDirectory.appendingPathComponent("\(name).swift"))
    }

    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParolaApp", isDirectory: true)
    }

    private func flattened(_ file: URL) throws -> String {
        let source = try String(contentsOf: file, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func appModelSources() throws -> [String: String] {
        let files = (FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("AppModel") && $0.pathExtension == "swift" }
        return try Dictionary(uniqueKeysWithValues: files.map {
            ($0.deletingPathExtension().lastPathComponent, try flattened($0))
        })
    }

    private func logCalls(in source: String) -> [String] {
        source.components(separatedBy: "ParolaLog.").dropFirst().map { chunk in
            var depth = 0
            var call = ""
            for character in chunk {
                call.append(character)
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            return call
        }
    }

    private func logsAnExport(_ call: String) -> Bool {
        call.split(separator: "(", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).hasPrefix(".export,") == true
    }

    @Test("the bulk library export logs the format and the entry, never the title")
    func libraryExportSite() throws {
        let source = try appSource("AppModel+Library")
        #expect(source.contains(
            #"var fields: [LogField: LogValue] = [.error: .error(error)] if let uuid = UUID(uuidString: String(entry.id.suffix(36))) { fields[.entry] = .id(uuid) } ParolaLog.error(.export, "library export failed as \(format)", fields)"#
        ))
    }

    @Test("no export site hands an error's localized description to the log")
    func exportSitesNeverLogLocalizedDescriptions() throws {
        let sources = try appModelSources()
        for (name, source) in sources {
            for call in logCalls(in: source) {
                #expect(call.contains("localizedDescription") == false, "\(name) logs a localized description")
            }
        }
        for name in ["AppModel", "AppModel+Export", "AppModel+Library"] {
            let exportCalls = logCalls(in: sources[name] ?? "").filter(logsAnExport)
            #expect(exportCalls.count >= 1, "\(name) no longer logs a failed export")
        }
    }
}
