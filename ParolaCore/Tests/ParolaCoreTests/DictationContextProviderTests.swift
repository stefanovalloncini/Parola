import Foundation
import Testing
@testable import ParolaCore

@Suite("Dictation context provider")
struct DictationContextProviderTests {
    private actor MockSource: DictationContextSource {
        var selectionCalls = 0
        var clipboardCalls = 0
        var screenCalls = 0

        var selectionResult: String?
        var clipboardResult: String?
        var screenResult: String?

        init(selection: String? = nil, clipboard: String? = nil, screen: String? = nil) {
            self.selectionResult = selection
            self.clipboardResult = clipboard
            self.screenResult = screen
        }

        func currentSelection() async -> String? {
            selectionCalls += 1
            return selectionResult
        }

        func clipboardContents() async -> String? {
            clipboardCalls += 1
            return clipboardResult
        }

        func windowOCR() async -> String? {
            screenCalls += 1
            return screenResult
        }
    }

    @Test("disabled config skips all source calls")
    func disabledConfigSkipsCalls() async {
        let source = MockSource(selection: "sel", clipboard: "clip", screen: "scr")
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(DictationContextConfig())
        #expect(context.isEmpty)
        let sCalls = await source.selectionCalls
        let cCalls = await source.clipboardCalls
        let scCalls = await source.screenCalls
        #expect(sCalls == 0)
        #expect(cCalls == 0)
        #expect(scCalls == 0)
    }

    @Test("only enabled flags trigger their source method")
    func onlyEnabledFlagsCalled() async {
        let source = MockSource(selection: "sel", clipboard: "clip", screen: "scr")
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(
            DictationContextConfig(selectionEnabled: true, clipboardEnabled: false, screenEnabled: false)
        )
        #expect(context.selection == "sel")
        #expect(context.clipboard == nil)
        #expect(context.screen == nil)
        let sCalls = await source.selectionCalls
        let cCalls = await source.clipboardCalls
        let scCalls = await source.screenCalls
        #expect(sCalls == 1)
        #expect(cCalls == 0)
        #expect(scCalls == 0)
    }

    @Test("nil values are filtered from the final context")
    func nilSourcesFiltered() async {
        let source = MockSource(selection: nil, clipboard: "clip", screen: nil)
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(
            DictationContextConfig(selectionEnabled: true, clipboardEnabled: true, screenEnabled: true)
        )
        #expect(context.selection == nil)
        #expect(context.clipboard == "clip")
        #expect(context.screen == nil)
    }

    @Test("empty strings collapse to nil")
    func emptyStringsCollapseToNil() async {
        let source = MockSource(selection: "   \n  ", clipboard: "real", screen: "")
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(
            DictationContextConfig(selectionEnabled: true, clipboardEnabled: true, screenEnabled: true)
        )
        #expect(context.selection == nil)
        #expect(context.clipboard == "real")
        #expect(context.screen == nil)
    }

    @Test("oversized text is capped at the per-source limit")
    func textIsCapped() async {
        let huge = String(repeating: "x", count: DictationContextProvider.selectionCap + 500)
        let source = MockSource(selection: huge, clipboard: nil, screen: nil)
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(
            DictationContextConfig(selectionEnabled: true, clipboardEnabled: false, screenEnabled: false)
        )
        #expect(context.selection?.count == DictationContextProvider.selectionCap)
    }

    @Test("empty context produces an empty prompt block")
    func emptyContextEmptyPrompt() {
        let context = DictationContext.empty
        #expect(context.promptBlock() == "")
    }

    @Test("prompt block wraps each present source in its xml tag")
    func promptBlockShape() {
        let context = DictationContext(
            selection: "Alice Wong",
            clipboard: "snake_case_var",
            screen: "Sprint 14"
        )
        let block = context.promptBlock()
        #expect(block.contains("<CURRENTLY_SELECTED_TEXT>Alice Wong</CURRENTLY_SELECTED_TEXT>"))
        #expect(block.contains("<CLIPBOARD_CONTEXT>snake_case_var</CLIPBOARD_CONTEXT>"))
        #expect(block.contains("<CURRENT_WINDOW_CONTEXT>Sprint 14</CURRENT_WINDOW_CONTEXT>"))
        #expect(block.contains("Do NOT echo, summarize, or respond"))
    }

    @Test("prompt block omits tags for nil sources")
    func promptBlockOmitsNil() {
        let context = DictationContext(selection: "only this", clipboard: nil, screen: nil)
        let block = context.promptBlock()
        #expect(block.contains("<CURRENTLY_SELECTED_TEXT>only this</CURRENTLY_SELECTED_TEXT>"))
        #expect(!block.contains("<CLIPBOARD_CONTEXT>"))
        #expect(!block.contains("<CURRENT_WINDOW_CONTEXT>"))
    }

    @Test("gather with timeout returns whatever finishes first")
    func gatherWithTimeout() async {
        let source = MockSource(selection: "sel", clipboard: nil, screen: nil)
        let provider = DictationContextProvider(source: source)
        let context = await provider.gather(
            DictationContextConfig(selectionEnabled: true, clipboardEnabled: false, screenEnabled: false),
            timeout: .seconds(1.5)
        )
        #expect(context.selection == "sel")
    }
}
