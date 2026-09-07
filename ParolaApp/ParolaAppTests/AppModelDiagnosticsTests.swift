import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("App diagnostics export")
struct AppModelDiagnosticsTests {

    private func makeModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("diagnostics"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker()
        )
        return AppModel(bootstrap: bootstrap)
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func seedRecord(in directory: URL, message: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line: [String: Any] = [
            "schemaVersion": 1,
            "ts": "2026-09-05T09:14:02.001Z",
            "level": "error",
            "subsystem": "app.parola.core",
            "category": "models",
            "message": message,
            "template": message,
            "file": "Seed.swift",
            "line": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        try (data + Data([0x0A])).write(to: directory.appendingPathComponent("parola-1-1757062442.jsonl"))
    }

    private func queueDestination(_ model: AppModel, _ url: URL) async throws {
        let picker = try #require(model.filePicker as? TestFilePicker)
        await picker.queueSaveResponse(url)
    }

    @Test("export writes the report to the chosen destination")
    func exportWritesTheReport() async throws {
        let model = makeModel()
        let source = scratchDirectory()
        try seedRecord(in: source, message: "seeded export record")
        let destination = scratchDirectory().appendingPathComponent("Parola-Diagnostics.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await queueDestination(model, destination)

        let written = try #require(try await model.exportDiagnostics(directory: source))
        #expect(written == destination)

        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.hasPrefix("Parola Diagnostics — generated "))
        #expect(text.contains("No transcript text, file names, or paths are included."))
        #expect(text.contains("\nApp "))
        #expect(text.contains("\nPermissions  "))
        #expect(text.contains("\nEngines registered  whisperkit=ok parakeet=ok apple-speech=ok"))
        #expect(text.contains("\nModels       "))
        #expect(text.contains("\nLibrary      "))
        #expect(text.contains("\nFeatures     "))
        #expect(text.contains("seeded export record"))
    }

    @Test("export from a directory that was never created still writes the header")
    func exportWithoutRecords() async throws {
        let model = makeModel()
        let destination = scratchDirectory().appendingPathComponent("empty.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await queueDestination(model, destination)

        let absent = scratchDirectory()
        let written = try #require(try await model.exportDiagnostics(directory: absent))

        let text = try String(contentsOf: written, encoding: .utf8)
        #expect(text.hasPrefix("Parola Diagnostics — generated "))
        #expect(text.contains("No diagnostics recorded."))
    }

    @Test("a cancelled save panel writes nothing")
    func exportCancelled() async throws {
        let model = makeModel()
        let source = scratchDirectory()
        try seedRecord(in: source, message: "not exported")
        #expect(try await model.exportDiagnostics(directory: source) == nil)
    }

    @Test("a destination that cannot be written throws instead of reporting a cancel")
    func exportWriteFailureThrows() async throws {
        let model = makeModel()
        let source = scratchDirectory()
        try seedRecord(in: source, message: "not written")
        let destination = scratchDirectory().appendingPathComponent("missing/report.txt")
        try await queueDestination(model, destination)

        await #expect(throws: (any Error).self) {
            try await model.exportDiagnostics(directory: source)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("delete removes the sink files and tolerates a directory that is not there")
    func deleteRemovesRecords() async throws {
        let model = makeModel()
        let directory = scratchDirectory()
        try seedRecord(in: directory, message: "deleted record")
        #expect(await model.diagnosticsRecordsExist(directory: directory))

        await model.deleteDiagnostics(directory: directory)
        #expect(await model.diagnosticsRecordsExist(directory: directory) == false)

        let absent = scratchDirectory()
        await model.deleteDiagnostics(directory: absent)
        #expect(await model.diagnosticsRecordsExist(directory: absent) == false)
    }

    @Test("delete leaves files the sink did not write")
    func deleteMatchesTheSinkPrefix() async throws {
        let model = makeModel()
        let directory = scratchDirectory()
        try seedRecord(in: directory, message: "sink record")
        let stranger = directory.appendingPathComponent("notes.jsonl")
        try "{}\n".write(to: stranger, atomically: true, encoding: .utf8)

        await model.deleteDiagnostics(directory: directory)

        #expect(FileManager.default.fileExists(atPath: stranger.path))
        #expect(await model.diagnosticsRecordsExist(directory: directory) == false)
    }

    @Test("reveal creates the directory so Finder always has something to show")
    func revealCreatesTheDirectory() async throws {
        let model = makeModel()
        let directory = scratchDirectory()
        await model.revealDiagnostics(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("permission mapping covers granted, denied and undetermined")
    func permissionMapping() {
        #expect(AppModel.diagnosticsPermission(authorized: true, undetermined: false) == .granted)
        #expect(AppModel.diagnosticsPermission(authorized: false, undetermined: true) == .undetermined)
        #expect(AppModel.diagnosticsPermission(authorized: false, undetermined: false) == .denied)
        #expect(AppModel.diagnosticsPermission(granted: true) == .granted)
        #expect(AppModel.diagnosticsPermission(granted: false) == .denied)
        #expect(AppModel.diagnosticsPermission(for: .granted) == .granted)
        #expect(AppModel.diagnosticsPermission(for: .undetermined) == .undetermined)
        #expect(AppModel.diagnosticsPermission(for: .denied) == .denied)
    }

    @Test("the environment reports the app version and every known engine")
    func environmentReportsAppFacts() async throws {
        let model = makeModel()
        let environment = await model.diagnosticsEnvironment()
        #expect(environment.appVersion == AboutInfo.versionString)
        #expect(environment.engines.keys.sorted { $0.rawValue < $1.rawValue }
            == [EngineID.appleSpeech, .parakeet, .whisperKit])
        #expect(environment.libraryEntryCount == 0)
    }

    @Test("the bridge command returns the path it wrote")
    func bridgeExportReturnsThePath() async throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let command = try #require(
            server.diagnosticsCommands().first { $0.name == "exportDiagnostics" }
        )

        let destination = scratchDirectory().appendingPathComponent("bridge.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await queueDestination(model, destination)

        let reply = try await command.handler(AutomationArgs(), context)
        withExtendedLifetime(server) {}
        #expect(reply == .object(["path": .string(destination.path)]))
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.hasPrefix("Parola Diagnostics — generated "))
    }

    @Test("the bridge separates a dismissed panel from a failed write")
    func bridgeSeparatesCancelFromFailure() async throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let command = try #require(
            server.diagnosticsCommands().first { $0.name == "exportDiagnostics" }
        )

        do {
            _ = try await command.handler(AutomationArgs(), context)
            Issue.record("expected the handler to throw")
        } catch let error as AutomationError {
            #expect(error.code == "PRECONDITION")
        }

        try await queueDestination(model, scratchDirectory().appendingPathComponent("missing/x.txt"))
        do {
            _ = try await command.handler(AutomationArgs(), context)
            Issue.record("expected the handler to throw")
        } catch let error as AutomationError {
            #expect(error.code == "INTERNAL")
        }
        withExtendedLifetime(server) {}
    }

    @Test("an engine the registry does not know reports unavailable")
    func enginesReflectTheRegistry() async {
        let registry = EngineRegistry()
        let unknown = await AppModel.diagnosticsEngines(registry: registry)
        #expect(unknown == [.whisperKit: false, .parakeet: false, .appleSpeech: false])

        await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
        let known = await AppModel.diagnosticsEngines(registry: registry)
        #expect(known[.whisperKit] == true)
        #expect(known[.parakeet] == true)
    }

    private func aboutPaneSource() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParolaApp/Views/Settings/AboutPane.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// Bounds the slice by the group's own braces, not the next `SettingsSection(` call — AboutPane has only one, so that search would never bound anything.
    private func matchingBraceRange(from openBrace: String.Index, in text: String) -> Range<String.Index> {
        var depth = 0
        var cursor = openBrace
        while cursor < text.endIndex {
            switch text[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return openBrace..<text.index(after: cursor) }
            default: break
            }
            cursor = text.index(after: cursor)
        }
        return openBrace..<text.endIndex
    }

    /// A hosted view builds no accessibility elements until a client attaches, so the ids are pinned in source.
    @Test("the About pane tags the diagnostics group for the bridge")
    func aboutPaneExposesAccessibilityIdentifiers() throws {
        let text = try aboutPaneSource()
        let group = try #require(text.range(of: "SettingsSection(\"Diagnostics\")"))
        let openBrace = try #require(text.range(of: "{", range: group.upperBound..<text.endIndex)).lowerBound
        let body = matchingBraceRange(from: openBrace, in: text)
        let diagnostics = text[group.lowerBound..<body.upperBound]
        for (control, identifier) in [
            ("Button(\"Export…\")", "About.Button.ExportDiagnostics"),
            ("Button(\"Reveal in Finder\")", "About.Button.RevealDiagnostics"),
            ("Button(\"Delete Diagnostics\"", "About.Button.DeleteDiagnostics"),
            ("Text(\"Kept for", "About.Text.DiagnosticsRetention"),
        ] {
            let tag = ".axLeaf(\"\(identifier)\")"
            let start = try #require(diagnostics.range(of: control), "AboutPane lost \(control)")
            let tagged = try #require(diagnostics.range(of: tag), "AboutPane lost \(identifier)")
            #expect(tagged.lowerBound > start.lowerBound, "\(identifier) no longer tags \(control)")
        }
    }

    /// A record written while the pane is open must not leave "Delete Diagnostics" stale until it remounts — pin the refresh, not just the initial read.
    @Test("the About pane's diagnostics check re-runs on app activation, not only on appear")
    func aboutPaneRefreshesDiagnosticsOnActivation() throws {
        let text = try aboutPaneSource()
        let task = try #require(text.range(of: ".task {"))
        let openBrace = try #require(text.range(of: "{", range: task.lowerBound..<text.endIndex)).lowerBound
        let body = matchingBraceRange(from: openBrace, in: text)
        let taskBody = text[body]
        #expect(taskBody.contains("diagnosticsRecordsExist()"))
        #expect(
            taskBody.contains("NSApplication.didBecomeActiveNotification"),
            "the diagnostics check should re-run when the app becomes active, not just once on appear"
        )
    }
}
