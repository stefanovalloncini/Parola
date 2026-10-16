import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

@MainActor
@Suite("Save panels go through the file picker", .serialized)
struct SaveThroughFilePickerTests {
    private func makeModel(picker: TestFilePicker) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("save-picker"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: picker
        ))
    }

    private func destination(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("save-picker-\(UUID().uuidString)-\(name)")
    }

    @Test("Export… in Snippets asks for parola-snippets.json as JSON and writes the snippets there")
    func snippets() async throws {
        let picker = TestFilePicker()
        let url = destination("snippets.json")
        defer { try? FileManager.default.removeItem(at: url) }
        await picker.queueSaveResponse(url)
        let model = makeModel(picker: picker)
        model.snippets = [Snippet(trigger: "brb", replacement: "be right back")]

        await model.exportSnippetsToFile()

        #expect(await picker.saveRequests == [.init(suggestedName: "parola-snippets.json", allowedTypes: [.json])])
        let written = try JSONDecoder().decode([Snippet].self, from: Data(contentsOf: url))
        #expect(written.map(\.trigger) == ["brb"])
    }

    @Test("a cancelled snippets export writes nothing")
    func snippetsCancelled() async {
        let picker = TestFilePicker()
        let model = makeModel(picker: picker)
        model.snippets = [Snippet(trigger: "a", replacement: "b")]

        await model.exportSnippetsToFile()

        #expect(await picker.saveRequests.count == 1)
        #expect(model.exportNotice == nil)
    }

    @Test("Save Captions… asks for captions-<stamp>.txt as plain text and writes the history there")
    func captions() async throws {
        let picker = TestFilePicker()
        let url = destination("captions.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        await picker.queueSaveResponse(url)
        let controller = LiveCaptionsController(showsPanel: false)
        controller.state = LiveCaptionsState(confirmedLines: ["Hello there", "General Kenobi"])

        await controller.saveCaptionsHistory(using: picker)

        let request = try #require(await picker.saveRequests.first)
        #expect(request.suggestedName.hasPrefix("captions-") && request.suggestedName.hasSuffix(".txt"))
        #expect(request.allowedTypes == [.plainText])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("General Kenobi"))
    }

    @Test("Save Captions… with no history never asks")
    func captionsEmpty() async {
        let picker = TestFilePicker()
        await LiveCaptionsController(showsPanel: false).saveCaptionsHistory(using: picker)
        #expect(await picker.saveRequests.isEmpty)
    }

    @Test("Export Settings asks for parola.parola-settings and writes the payload there")
    func settings() async throws {
        let picker = TestFilePicker()
        let url = destination("settings.parola-settings")
        defer { try? FileManager.default.removeItem(at: url) }
        await picker.queueSaveResponse(url)

        let failure = await SettingsExportService.exportSettings(using: picker)

        #expect(failure == nil)
        #expect(await picker.saveRequests.first?.suggestedName == "parola.parola-settings")
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [String: Any])
    }
}
