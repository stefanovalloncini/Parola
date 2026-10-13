import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Model details", .serialized)
struct ModelDetailsTests {

    private static let turbo = "openai_whisper-large-v3_turbo"

    private func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    private func info(_ name: String, installed: Bool, path: String?) -> ModelInfo {
        ModelInfo(
            name: name,
            label: AppModel.modelLabel(name),
            approximateSizeBytes: nil,
            isMultilingual: true,
            isInstalled: installed,
            installedURL: path.map { URL(fileURLWithPath: $0) }
        )
    }

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    @Test("an installed model names itself, its engine, its source, its path and its measured size")
    func installedModelDetails() {
        let model = makeModel("details-installed")
        model.availableModels = [info(Self.turbo, installed: true, path: "/tmp/models/turbo")]
        model.modelSizes = [Self.turbo: 1_600_000_000]
        model.selectedModel = Self.turbo

        let out = lines(model.modelDetailsText())

        #expect(out.contains("Model: Whisper Large v3 Turbo"))
        #expect(out.contains("Identifier: \(Self.turbo)"))
        #expect(out.contains("Engine: WhisperKit"))
        #expect(out.contains("Source: argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"))
        #expect(out.contains("Installed: yes"))
        #expect(out.contains("Path: /tmp/models/turbo"))
        #expect(out.contains("Size: \(AppFormat.byteSize(Int64(1_600_000_000)))"))
        #expect(out.contains("Languages: every language the engine knows"))
    }

    @Test("a model that isn't on disk says so and offers no path or size")
    func uninstalledModelDetails() {
        let model = makeModel("details-uninstalled")
        model.availableModels = [info(Self.turbo, installed: false, path: nil)]
        model.selectedModel = Self.turbo

        let out = lines(model.modelDetailsText())

        #expect(out.contains("Installed: no"))
        #expect(out.contains { $0.hasPrefix("Path: ") } == false)
        #expect(out.contains { $0.hasPrefix("Size: ") } == false)
    }

    @Test("an installed model with no measurement yet falls back to the catalog estimate")
    func estimatedSize() {
        let model = makeModel("details-estimate")
        model.availableModels = [info(Self.turbo, installed: true, path: "/tmp/models/turbo")]
        model.modelSizes = [:]
        model.selectedModel = Self.turbo

        let out = lines(model.modelDetailsText())
        let catalogSize = ModelCatalog.variant(id: Self.turbo)?.sizeBytes ?? 0

        #expect(out.contains("Size: about \(AppFormat.byteSize(catalogSize))"))
    }

    @Test("an English-only model says so")
    func englishOnlyLanguageSummary() {
        #expect(AppModel.modelLanguageSummary(for: "nvidia_parakeet-tdt-0.6b-v2") == "English only")
    }

    @Test("a model with a language list counts it")
    func countedLanguageSummary() {
        let summary = AppModel.modelLanguageSummary(for: "nvidia_parakeet-tdt-0.6b-v3")
        #expect(summary.hasSuffix("languages"))
        #expect(summary != "English only")
    }

    @Test("a model the catalog doesn't know still names itself")
    func unknownModelDetails() {
        let model = makeModel("details-unknown")
        model.selectedModel = "totally-made-up-model"

        let out = lines(model.modelDetailsText())

        #expect(out == ["Model: totally-made-up-model", "This build's catalog has no entry for it."])
    }

    @Test("the bridge copies the same block it returns")
    func bridgeReturnsTheSameText() async throws {
        try await withPasteboardRestored { try await checkBridgeCopy() }
    }

    private func checkBridgeCopy() async throws {
        let model = makeModel("details-bridge")
        await model.awaitModelListRefresh()
        model.availableModels = [info(Self.turbo, installed: true, path: "/tmp/models/turbo")]
        model.modelSizes = [Self.turbo: 1_600_000_000]
        model.selectedModel = Self.turbo
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.modelCommands().map { ($0.name, $0) })
        let command = try #require(commands["copyModelDetails"])
        let args = try command.validate(AutomationArgs([:]))

        let reply = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        guard case .object(let fields) = reply, case .string(let text)? = fields["text"] else {
            Issue.record("copyModelDetails returned no text")
            return
        }
        #expect(text == model.modelDetailsText())
        #expect(NSPasteboard.general.string(forType: .string) == text)
    }
}
