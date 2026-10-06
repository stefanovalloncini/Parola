import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

@MainActor
@Suite("Rule list panes", .serialized)
struct RuleListPanesTests {
    enum Pane: CaseIterable, Sendable {
        case snippets, corrections, ignoredSegments, findReplace

        var prefix: String {
            switch self {
            case .snippets: "Snippets"
            case .corrections: "Corrections"
            case .ignoredSegments: "IgnoredSegments"
            case .findReplace: "FindReplace"
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .snippets: SnippetsPane()
            case .corrections: CorrectionsPane()
            case .ignoredSegments: IgnoredSegmentsPane()
            case .findReplace: FindReplacePane()
            }
        }

        @MainActor func fill(_ model: AppModel, count: Int) {
            let words = (0..<count).map { "word\($0)" }
            switch self {
            case .snippets: model.snippets = words.map { Snippet(trigger: $0, replacement: $0.uppercased()) }
            case .corrections: model.correctionRules = words.map { CorrectionRule(from: $0, to: $0.uppercased()) }
            case .ignoredSegments: model.ignoredSegmentRules = words.map { IgnoredSegmentRule(pattern: $0) }
            case .findReplace: model.findReplaceRules = words.map { FindReplaceRule(find: $0, replace: $0.uppercased()) }
            }
        }
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("rule-lists"))
    }

    private func elements(_ pane: Pane, rules: Int) -> [HostedAccessibility.Element] {
        let model = makeModel()
        pane.fill(model, count: rules)
        let hosted = HostedWindow(ScrollView { pane.view.padding() }.environment(model), width: 900, height: 2400)
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
    }

    @Test("a long list gets the same toolbar on every pane: search, the enabled filter and sort on one line",
          arguments: Pane.allCases)
    func longListToolbar(_ pane: Pane) throws {
        let found = elements(pane, rules: RuleListQuery.toolbarThreshold)
        let search = try #require(found.first { $0.identifier?.hasSuffix("\(pane.prefix).TextField.Search") == true })
        let sort = try #require(found.first { $0.identifier?.hasSuffix("\(pane.prefix).Menu.Sort") == true })
        let chips = found.filter { $0.words.contains(String(localized: "Disabled")) }
        #expect(chips.isEmpty == false, "\(pane.prefix) has no enabled filter")
        #expect(abs(search.frame.midY - sort.frame.midY) < 8, "\(pane.prefix): search and sort sit on different lines")
        for chip in chips {
            #expect(abs(search.frame.midY - chip.frame.midY) < 8, "\(pane.prefix): the filter sits on its own line")
        }
    }

    @Test("a short list has no search field or filter over it", arguments: Pane.allCases)
    func shortListHasNoToolbar(_ pane: Pane) {
        let found = elements(pane, rules: 2)
        let ids = found.compactMap(\.identifier)
        #expect(!ids.contains { $0.hasSuffix("\(pane.prefix).TextField.Search") }, "\(pane.prefix) shows search over 2 rules")
        #expect(!ids.contains { $0.hasSuffix("\(pane.prefix).Menu.Sort") }, "\(pane.prefix) shows sort over 2 rules")
    }

    @Test("case-sensitivity is the same labelled checkbox in Corrections and Find & Replace")
    func oneCaseSensitivityControl() throws {
        for pane in [Pane.corrections, .findReplace] {
            let found = elements(pane, rules: 1)
            let control = try #require(found.first { $0.identifier?.hasSuffix("\(pane.prefix).Toggle.CaseSensitive") == true })
            #expect(control.role == NSAccessibility.Role.checkBox.rawValue)
            #expect(control.name == String(localized: "Case-sensitive"), "\(pane.prefix) names it \(control.name ?? "nothing")")
        }
    }

    @Test("Find & Replace doesn't repeat its header under the list")
    func findReplaceHelperIsNotTheHeader() {
        let words = elements(.findReplace, rules: 1)
            .flatMap(\.words)
        #expect(!words.contains { $0.hasPrefix("Substitutions applied to every") })
    }

    @Test("the toolbar shows from the threshold, or while it narrows the list")
    func toolbarThreshold() {
        let idle = RuleListQuery()
        #expect(idle.showsToolbar(ruleCount: RuleListQuery.toolbarThreshold - 1) == false)
        #expect(idle.showsToolbar(ruleCount: RuleListQuery.toolbarThreshold))
        #expect(RuleListQuery(search: "x").showsToolbar(ruleCount: 1))
        #expect(RuleListQuery(filter: .disabled).showsToolbar(ruleCount: 1))
        #expect(RuleListQuery(sort: .descending).showsToolbar(ruleCount: 1))
    }

    @Test("the query filters, searches every field and sorts with ties in list order")
    func arrange() {
        struct Rule: Equatable { let a: String; let b: String; let on: Bool }
        let rules = [
            Rule(a: "beta", b: "x", on: true),
            Rule(a: "Alpha", b: "y", on: false),
            Rule(a: "beta", b: "z", on: false),
            Rule(a: "gamma", b: "beta", on: true),
        ]
        let fields: (Rule) -> [String] = { [$0.a, $0.b] }
        let isOn: (Rule) -> Bool = { $0.on }
        #expect(RuleListQuery(search: "BETA").arrange(rules, fields: fields, isEnabled: isOn) == [rules[0], rules[2], rules[3]])
        #expect(RuleListQuery(filter: .disabled).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[2]])
        #expect(RuleListQuery(sort: .ascending).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[0], rules[2], rules[3]])
        #expect(RuleListQuery(sort: .descending).arrange(rules, fields: fields, isEnabled: isOn) == [rules[3], rules[0], rules[2], rules[1]])
        #expect(RuleListQuery(sort: .disabledFirst).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[2], rules[0], rules[3]])
        #expect(RuleListQuery(sort: .enabledFirst).arrange(rules, fields: fields, isEnabled: isOn) == [rules[0], rules[3], rules[1], rules[2]])
    }
}
