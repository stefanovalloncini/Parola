import Foundation
import Testing
@testable import ParolaCore

@Suite("DictationWorkflow")
struct DictationWorkflowTests {
    @Test("decodes legacy [bundleID: promptID] JSON")
    func decodesLegacy() {
        let legacy = #"{"com.apple.mail":"abc","com.tinyspeck.slackmacgap":"def"}"#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: legacy)
        #expect(map["com.apple.mail"]?.first?.promptID == "abc")
        #expect(map["com.tinyspeck.slackmacgap"]?.first?.promptID == "def")
        #expect(map["com.apple.mail"]?.first?.language == nil)
    }

    @Test("decodes nested workflow JSON")
    func decodesNested() {
        let nested = #"""
        {"com.apple.mail":{"promptID":"abc","language":"it"}}
        """#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: nested)
        #expect(map["com.apple.mail"]?.first?.promptID == "abc")
        #expect(map["com.apple.mail"]?.first?.language == "it")
    }

    @Test("empty workflows are dropped during decode")
    func dropsEmpty() {
        let legacy = #"{"a":"","b":"keep"}"#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: legacy)
        #expect(map["a"] == nil)
        #expect(map["b"]?.first?.promptID == "keep")
    }

    @Test("round-trips through encode/decode")
    func roundTrip() {
        let original: [String: [DictationWorkflow]] = [
            "com.apple.mail": [DictationWorkflow(promptID: "abc", language: "it")],
            "com.apple.Notes": [DictationWorkflow(promptID: "xyz")]
        ]
        let data = DictationWorkflowMap.encode(original)
        let decoded = DictationWorkflowMap.decode(legacy: data)
        #expect(decoded == original)
    }

    @Test("insertion mode round-trips")
    func insertionMode() {
        let original: [String: [DictationWorkflow]] = [
            "com.apple.Terminal": [DictationWorkflow(insertion: .keystroke)]
        ]
        let data = DictationWorkflowMap.encode(original)
        let decoded = DictationWorkflowMap.decode(legacy: data)
        #expect(decoded["com.apple.Terminal"]?.first?.insertion == .keystroke)
    }
}
