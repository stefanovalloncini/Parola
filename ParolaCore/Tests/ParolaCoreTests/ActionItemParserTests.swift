import Foundation
import Testing
@testable import ParolaCore

@Suite("Action item parser")
struct ActionItemParserTests {
    @Test("empty input yields empty list")
    func emptyInput() {
        #expect(ActionItemParser.parse("").isEmpty)
        #expect(ActionItemParser.parse("   \n\n").isEmpty)
    }

    @Test("strips dash, asterisk, and bullet markers")
    func stripsBulletMarkers() {
        let items = ActionItemParser.parse("""
        - send report
        * call the vendor
        • file the receipt
        """)
        #expect(items.map(\.task) == ["send report", "call the vendor", "file the receipt"])
    }

    @Test("parses assignee in leading brackets")
    func parsesAssignee() {
        let items = ActionItemParser.parse("- [Stefano] should send the report")
        #expect(items.count == 1)
        #expect(items[0].assignee == "Stefano")
        #expect(items[0].task == "should send the report")
        #expect(items[0].dueDate == nil)
    }

    @Test("parses due date in trailing brackets")
    func parsesDueDate() {
        let items = ActionItemParser.parse("- [Alice] should review the PR [by tomorrow]")
        #expect(items.count == 1)
        #expect(items[0].assignee == "Alice")
        #expect(items[0].task == "should review the PR")
        #expect(items[0].dueDate == "tomorrow")
    }

    @Test("treats by-prefixed trailing brackets case-insensitively")
    func dueDateCaseInsensitive() {
        let items = ActionItemParser.parse("- [Bob] ship the migration [BY Friday]")
        #expect(items[0].dueDate == "Friday")
    }

    @Test("lines without leading brackets parse with nil assignee")
    func noAssignee() {
        let items = ActionItemParser.parse("- send the report by Friday")
        #expect(items.count == 1)
        #expect(items[0].assignee == nil)
        #expect(items[0].task == "send the report by Friday")
    }

    @Test("skips lines that don't begin with a bullet")
    func skipsPreamble() {
        let items = ActionItemParser.parse("""
        Here are the action items I extracted:
        - [Stefano] ship the migration
        - call the vendor
        Let me know if you'd like more.
        """)
        #expect(items.count == 2)
        #expect(items[0].assignee == "Stefano")
        #expect(items[1].assignee == nil)
    }

    @Test("empty bracket pair is ignored")
    func emptyBracketIgnored() {
        let items = ActionItemParser.parse("- [] follow up tomorrow")
        #expect(items.count == 1)
        #expect(items[0].assignee == nil)
        #expect(items[0].task == "follow up tomorrow")
    }

    @Test("trims whitespace inside fields")
    func trimsWhitespace() {
        let items = ActionItemParser.parse("-   [  Alice  ]   draft the spec   [by   Friday  ]")
        #expect(items[0].assignee == "Alice")
        #expect(items[0].task == "draft the spec")
        #expect(items[0].dueDate == "Friday")
    }

    @Test("parses numbered list markers")
    func parsesNumberedList() {
        let items = ActionItemParser.parse("""
        1. send the report
        2. call the vendor
        10. file the receipt
        """)
        #expect(items.map(\.task) == ["send the report", "call the vendor", "file the receipt"])
    }

    @Test("parses parenthesized numbered markers")
    func parsesParenNumbered() {
        let items = ActionItemParser.parse("""
        1) ship the migration
        2) review the PR
        """)
        #expect(items.map(\.task) == ["ship the migration", "review the PR"])
    }

    @Test("parses fields inside a numbered item")
    func numberedItemFields() {
        let items = ActionItemParser.parse("1. [Alice] should send the report [by Friday]")
        #expect(items.count == 1)
        #expect(items[0].assignee == "Alice")
        #expect(items[0].task == "should send the report")
        #expect(items[0].dueDate == "Friday")
    }

    @Test("does not treat a decimal number as a list marker")
    func decimalNotMarker() {
        #expect(ActionItemParser.parse("3.5 mg is the dosage").isEmpty)
    }
}
