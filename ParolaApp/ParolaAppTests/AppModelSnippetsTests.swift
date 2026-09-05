import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@MainActor
@Suite("AppModel snippets")
struct AppModelSnippetsTests {

    private func makeModel(_ defaults: UserDefaults? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults ?? temporaryDefaults(), libraryURL: makeTempLibraryURL("snippets"))
    }

    @Test("setting snippets persists them under the snippets key")
    func snippetsPersistOnSet() {
        let model = makeModel()
        model.snippets = [
            Snippet(trigger: "brb", replacement: "be right back"),
            Snippet(trigger: "omw", replacement: "on my way"),
        ]

        let stored = model.readJSON([Snippet].self, forKey: AppModel.snippetsDefaultsKey)
        #expect(stored?.map(\.trigger) == ["brb", "omw"])
    }

    @Test("a fresh model reloads the snippets a prior model saved")
    func snippetsRoundTrip() {
        let defaults = temporaryDefaults()
        let first = makeModel(defaults)
        first.snippets = [Snippet(trigger: "sig", replacement: "Best,\nStefano")]

        let reloaded = makeModel(defaults)

        #expect(reloaded.snippets.count == 1)
        #expect(reloaded.snippets.first?.trigger == "sig")
        #expect(reloaded.snippets.first?.replacement == "Best,\nStefano")
    }

    @Test("makeSnippetExpander expands an enabled, immediate trigger")
    func expanderExpandsImmediate() async {
        let model = makeModel()
        model.snippets = [Snippet(trigger: "ty", replacement: "thank you")]

        let expander = model.makeSnippetExpander()
        let output = await expander.process("ty for the help")

        #expect(output == "thank you for the help")
    }

    @Test("makeSnippetExpander skips disabled snippets")
    func expanderSkipsDisabled() async {
        let model = makeModel()
        model.snippets = [Snippet(trigger: "ty", replacement: "thank you", enabled: false)]

        let output = await model.makeSnippetExpander().process("ty")

        #expect(output == "ty")
    }

    @Test("makeSnippetExpander defers expand-at-insert snippets to the deferred pass")
    func expanderDefersInsertSnippets() async {
        let model = makeModel()
        model.snippets = [Snippet(trigger: "now", replacement: "later", expandAtInsert: true)]

        let immediate = await model.makeSnippetExpander().process("now")
        #expect(immediate == "now")

        let deferred = await model.makeSnippetExpander().deferredOnly().process("now")
        #expect(deferred == "later")
    }

    @Test("setting correction rules persists them under the corrections key")
    func correctionRulesPersist() {
        let model = makeModel()
        model.correctionRules = [
            CorrectionRule(from: "github", to: "GitHub"),
            CorrectionRule(from: "swiftui", to: "SwiftUI"),
        ]

        let stored = model.readJSON([CorrectionRule].self, forKey: AppModel.correctionRulesDefaultsKey)
        #expect(stored?.map(\.to) == ["GitHub", "SwiftUI"])
    }

    @Test("a fresh model reloads the correction rules a prior model saved")
    func correctionRulesRoundTrip() {
        let defaults = temporaryDefaults()
        let first = makeModel(defaults)
        first.correctionRules = [CorrectionRule(from: "macos", to: "macOS", caseSensitive: true)]

        let reloaded = makeModel(defaults)

        #expect(reloaded.correctionRules.count == 1)
        #expect(reloaded.correctionRules.first?.from == "macos")
        #expect(reloaded.correctionRules.first?.caseSensitive == true)
    }
}
