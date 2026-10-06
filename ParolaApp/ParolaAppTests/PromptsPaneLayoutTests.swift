import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Prompts pane layout", .serialized)
struct PromptsPaneLayoutTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("prompts-pane"))
    }

    private func host(_ model: AppModel) -> HostedWindow {
        HostedWindow(ScrollView { PromptsPane().padding() }.environment(model), width: 900, height: 2600)
    }

    private func ids(in hosted: HostedWindow) -> [String] {
        HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
    }

    private func waitFor(_ condition: () -> Bool, in hosted: HostedWindow) async {
        for _ in 0..<150 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
            hosted.host.layoutSubtreeIfNeeded()
        }
    }

    @Test("Add Prompt sits above the built-in prompts, under the custom ones")
    func addPromptComesBeforeTheBuiltIns() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let add = try #require(elements.first { $0.identifier?.hasSuffix("Prompts.Button.AddPrompt") == true })
        let firstBuiltIn = try #require(Prompt.builtIns.first)
        let row = try #require(elements.first { $0.words.contains(firstBuiltIn.name) })
        #expect(add.frame.minY > row.frame.maxY, "Add Prompt sits below the built-in list")
    }

    @Test("rows don't each say Built-in; the section does")
    func noPerRowKindLabel() {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let words = HostedAccessibility.words(in: hosted.host)
        #expect(words.filter { $0 == String(localized: "Built-in") }.count == 0)
        #expect(words.contains(String(localized: "Built-in prompts")))
        #expect(words.contains(String(localized: "Custom prompts")))
    }

    @Test("every built-in prompt can be opened")
    func builtInsOpen() {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let views = ids(in: hosted).filter { $0.hasSuffix("Prompts.Button.View") }
        #expect(views.count == Prompt.builtIns.count)
    }

    @Test("a built-in opens read-only, and Duplicate starts a new prompt from it")
    func viewAndDuplicate() throws {
        let builtIn = try #require(Prompt.builtIns.first)
        let viewing = PromptEditDraft(viewing: builtIn)
        #expect(viewing.isReadOnly)
        #expect(viewing.instructions == builtIn.instructions)

        let copy = viewing.duplicate()
        #expect(copy.isReadOnly == false)
        #expect(copy.isExisting == false)
        #expect(copy.id != builtIn.id)
        #expect(copy.name == String(localized: "\(builtIn.name) copy"))
        #expect(copy.instructions == builtIn.instructions)
        #expect(copy.assistantMode == viewing.assistantMode)
    }

    @Test("Delete on a custom prompt asks first")
    func deleteAsks() async {
        let model = makeModel()
        _ = await model.promptLibrary.addUserPrompt(name: "Mine", instructions: "Do it", triggerWords: [], useSystemInstructions: true)
        let hosted = host(model)
        defer { hosted.close() }
        await waitFor({ ids(in: hosted).contains { $0.hasSuffix("Prompts.Button.Delete") } }, in: hosted)

        #expect(HostedAccessibility.press(endingWith: "Prompts.Button.Delete", in: hosted.host))
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(20)) }
        let names = await model.promptLibrary.userPrompts.map(\.name)
        #expect(names == ["Mine"])
    }

    @Test("custom prompts list above the built-ins")
    func customFirst() async throws {
        let model = makeModel()
        _ = await model.promptLibrary.addUserPrompt(name: "Mine", instructions: "Do it", triggerWords: [], useSystemInstructions: true)
        let hosted = host(model)
        defer { hosted.close() }
        await waitFor({ HostedAccessibility.words(in: hosted.host).contains("Mine") }, in: hosted)
        let elements = HostedAccessibility.elements(in: hosted.host)
        let mine = try #require(elements.first { $0.words.contains("Mine") })
        let firstBuiltIn = try #require(Prompt.builtIns.first)
        let row = try #require(elements.first { $0.words.contains(firstBuiltIn.name) })
        #expect(mine.frame.minY > row.frame.maxY, "the custom prompt sits below the built-ins")
    }
}
