import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("AppModel post-process")
struct AppModelPostProcessTests {

    private func makeModel(_ defaults: UserDefaults? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults ?? UserDefaults(suiteName: "test-\(UUID())")!)
    }

    private static func transcript(_ texts: [String]) -> Transcript {
        let segments = texts.enumerated().map { idx, text in
            TranscriptSegment(id: idx, start: Double(idx), end: Double(idx) + 1, text: text)
        }
        return Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    @Test("postProcess drops segments that exactly match an ignored pattern")
    func dropsIgnoredSegments() {
        let model = makeModel()
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "uh")]

        let out = model.postProcess(Self.transcript(["Uh", "real content", " uh "]))

        #expect(out.segments.map(\.text) == ["real content"])
    }

    @Test("postProcess keeps a disabled ignore rule from filtering")
    func disabledIgnoreRuleNoOp() {
        let model = makeModel()
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "uh", enabled: false)]

        let out = model.postProcess(Self.transcript(["uh", "content"]))

        #expect(out.segments.count == 2)
    }

    @Test("postProcess applies find/replace to surviving segments")
    func appliesFindReplace() {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "color", replace: "colour")]

        let out = model.postProcess(Self.transcript(["the color is bright", "no match here"]))

        #expect(out.segments[0].text == "the colour is bright")
        #expect(out.segments[1].text == "no match here")
    }

    @Test("postProcess filters first, then rewrites the remaining text")
    func filtersThenRewrites() {
        let model = makeModel()
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "noise")]
        model.findReplaceRules = [FindReplaceRule(find: "teh", replace: "the")]

        let out = model.postProcess(Self.transcript(["noise", "teh end"]))

        #expect(out.segments.map(\.text) == ["the end"])
    }

    @Test("postProcess leaves the transcript untouched when no rules are set")
    func noRulesIsIdentity() {
        let model = makeModel()
        model.ignoredSegmentRules = []
        model.findReplaceRules = []
        let input = Self.transcript(["one", "two", "three"])

        let out = model.postProcess(input)

        #expect(out.segments == input.segments)
        #expect(out.language == input.language)
        #expect(out.modelName == input.modelName)
    }

    @Test("case-sensitive find/replace only matches the exact casing")
    func caseSensitiveFindReplace() {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "ios", replace: "iOS", caseSensitive: true)]

        let out = model.postProcess(Self.transcript(["ios and IOS"]))

        #expect(out.segments[0].text == "iOS and IOS")
    }

    @Test("a fresh model reloads the ignored-segment rules a prior model saved")
    func ignoredRulesRoundTrip() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let first = makeModel(defaults)
        first.ignoredSegmentRules = [
            IgnoredSegmentRule(pattern: "um"),
            IgnoredSegmentRule(pattern: "[music]", enabled: false),
        ]

        let reloaded = makeModel(defaults)

        #expect(reloaded.ignoredSegmentRules.map(\.pattern) == ["um", "[music]"])
        #expect(reloaded.ignoredSegmentRules.last?.enabled == false)
    }

    @Test("a fresh model reloads the find/replace rules a prior model saved")
    func findReplaceRulesRoundTrip() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let first = makeModel(defaults)
        first.findReplaceRules = [
            FindReplaceRule(find: "gmt", replace: "GMT"),
            FindReplaceRule(find: #"\d+"#, replace: "N", regex: true),
        ]

        let reloaded = makeModel(defaults)

        #expect(reloaded.findReplaceRules.map(\.find) == ["gmt", #"\d+"#])
        #expect(reloaded.findReplaceRules.last?.regex == true)
    }
}
