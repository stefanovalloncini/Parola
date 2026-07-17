import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("DictationWorkflow URL patterns")
struct DictationWorkflowURLTests {
    @Test("legacy single-workflow JSON wraps as singleton array with nil urlPattern")
    func migratesLegacySingleWorkflow() {
        let legacy = #"""
        {"com.google.Chrome":{"promptID":"abc","language":"it"}}
        """#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: legacy)
        let entries = map["com.google.Chrome"]
        #expect(entries?.count == 1)
        #expect(entries?.first?.promptID == "abc")
        #expect(entries?.first?.urlPattern == nil)
    }

    @Test("legacy flat [bundleID: promptID] JSON migrates with nil urlPattern")
    func migratesFlatLegacy() {
        let legacy = #"{"com.apple.mail":"abc"}"#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: legacy)
        #expect(map["com.apple.mail"]?.count == 1)
        #expect(map["com.apple.mail"]?.first?.promptID == "abc")
        #expect(map["com.apple.mail"]?.first?.urlPattern == nil)
    }

    @Test("decodes new array-shaped JSON")
    func decodesArrayShape() {
        let json = #"""
        {"com.google.Chrome":[
          {"promptID":"default-id"},
          {"promptID":"gmail-id","urlPattern":"gmail.com"}
        ]}
        """#.data(using: .utf8)!
        let map = DictationWorkflowMap.decode(legacy: json)
        let workflows = map["com.google.Chrome"]
        #expect(workflows?.count == 2)
        #expect(workflows?[0].urlPattern == nil)
        #expect(workflows?[1].urlPattern == "gmail.com")
    }

    @Test("encode/decode roundtrip preserves url patterns")
    func roundtripsArrayShape() {
        let original: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "default-id"),
                DictationWorkflow(promptID: "gmail-id", urlPattern: "gmail.com"),
                DictationWorkflow(promptID: "gh-id", urlPattern: "github.com")
            ]
        ]
        let data = DictationWorkflowMap.encode(original)
        let decoded = DictationWorkflowMap.decode(legacy: data)
        #expect(decoded == original)
    }

    @Test("matches(url:) is case-insensitive on host")
    func matchesHostCaseInsensitive() {
        let workflow = DictationWorkflow(urlPattern: "GMAIL.com")
        let url = URL(string: "https://mail.gmail.com/u/0/")!
        #expect(workflow.matches(url: url))
    }

    @Test("matches(url:) is case-insensitive on full URL")
    func matchesFullURLCaseInsensitive() {
        let workflow = DictationWorkflow(urlPattern: "/PR/")
        let url = URL(string: "https://github.com/owner/repo/pr/42")!
        #expect(workflow.matches(url: url))
    }

    @Test("matches(url:) returns false when pattern is empty or url is nil")
    func matchesGuards() {
        let empty = DictationWorkflow(urlPattern: "")
        let nilPattern = DictationWorkflow(urlPattern: nil)
        let url = URL(string: "https://example.com")!
        #expect(empty.matches(url: url) == false)
        #expect(nilPattern.matches(url: url) == false)
        let real = DictationWorkflow(urlPattern: "example.com")
        #expect(real.matches(url: nil) == false)
    }

    @Test("select picks URL-matching workflow over bundle default")
    func selectPrefersURLMatch() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "default-id"),
                DictationWorkflow(promptID: "gmail-id", urlPattern: "gmail.com")
            ]
        ]
        let chosen = DictationWorkflowMap.select(
            in: map,
            for: "com.google.Chrome",
            url: URL(string: "https://mail.gmail.com/u/0/")
        )
        #expect(chosen?.promptID == "gmail-id")
    }

    @Test("select falls back to bundle default when URL doesn't match")
    func selectFallsBackToDefault() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "default-id"),
                DictationWorkflow(promptID: "gmail-id", urlPattern: "gmail.com")
            ]
        ]
        let chosen = DictationWorkflowMap.select(
            in: map,
            for: "com.google.Chrome",
            url: URL(string: "https://news.ycombinator.com")
        )
        #expect(chosen?.promptID == "default-id")
    }

    @Test("select returns first URL match when multiple match")
    func selectReturnsFirstMatch() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "first", urlPattern: "github.com"),
                DictationWorkflow(promptID: "second", urlPattern: ".com")
            ]
        ]
        let chosen = DictationWorkflowMap.select(
            in: map,
            for: "com.google.Chrome",
            url: URL(string: "https://github.com/foo/bar")
        )
        #expect(chosen?.promptID == "first")
    }

    @Test("select returns nil for unknown bundleID")
    func selectReturnsNilForUnknownBundle() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [DictationWorkflow(promptID: "abc")]
        ]
        let chosen = DictationWorkflowMap.select(in: map, for: "com.apple.Safari", url: nil)
        #expect(chosen == nil)
    }

    @Test("defaultWorkflow returns the entry without a URL pattern")
    func defaultWorkflowFinder() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "gmail-id", urlPattern: "gmail.com"),
                DictationWorkflow(promptID: "default-id")
            ]
        ]
        let def = DictationWorkflowMap.defaultWorkflow(in: map, for: "com.google.Chrome")
        #expect(def?.promptID == "default-id")
    }

    @Test("urlRules returns only entries with a URL pattern")
    func urlRulesFinder() {
        let map: [String: [DictationWorkflow]] = [
            "com.google.Chrome": [
                DictationWorkflow(promptID: "default-id"),
                DictationWorkflow(promptID: "gmail-id", urlPattern: "gmail.com"),
                DictationWorkflow(promptID: "gh-id", urlPattern: "github.com")
            ]
        ]
        let rules = DictationWorkflowMap.urlRules(in: map, for: "com.google.Chrome")
        #expect(rules.count == 2)
        #expect(rules.contains(where: { $0.promptID == "gmail-id" }))
        #expect(rules.contains(where: { $0.promptID == "gh-id" }))
    }

    @Test("urlPattern in isEmpty: empty pattern alone doesn't make it non-empty")
    func emptinessIgnoresBlankPattern() {
        let workflow = DictationWorkflow(urlPattern: "")
        #expect(workflow.isEmpty)
        let nonempty = DictationWorkflow(urlPattern: "gmail.com")
        #expect(nonempty.isEmpty == false)
    }

    @Test("hasURLRules is true only when an entry carries a pattern")
    func hasURLRulesDetection() {
        let none: [String: [DictationWorkflow]] = ["b": [DictationWorkflow(insertion: .paste)]]
        #expect(DictationWorkflowMap.hasURLRules(in: none, for: "b") == false)
        #expect(DictationWorkflowMap.hasURLRules(in: none, for: "missing") == false)
        let some: [String: [DictationWorkflow]] = ["b": [DictationWorkflow(urlPattern: "gmail.com")]]
        #expect(DictationWorkflowMap.hasURLRules(in: some, for: "b"))
    }
}
