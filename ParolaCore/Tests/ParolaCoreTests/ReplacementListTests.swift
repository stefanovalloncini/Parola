import Foundation
import Testing
@testable import ParolaCore

@Suite("Replacement list import")
struct ReplacementListTests {
    private func pairs(_ list: ReplacementList) -> [String] {
        list.rules.map { "\($0.find)=>\($0.replace)" }
    }

    @Test("CSV with two columns")
    func csv() {
        let list = ReplacementList.parse("cat,dog\nfoo,bar\n", fileExtension: "csv")
        #expect(pairs(list) == ["cat=>dog", "foo=>bar"])
        #expect(list.skippedLines == 0)
    }

    @Test("imported rules are enabled whole-word, insensitive, not regex")
    func ruleFlags() throws {
        let rule = try #require(ReplacementList.parse("a,b", fileExtension: "csv").rules.first)
        #expect(rule.wholeWord && rule.enabled && !rule.caseSensitive && !rule.regex)
    }

    @Test("CSV quoting: commas, escaped quotes, newlines in a field")
    func csvQuoting() {
        let text = "\"a, b\",\"say \"\"hi\"\"\"\nx,\"line1\nline2\"\n"
        #expect(pairs(ReplacementList.parse(text, fileExtension: "csv")) == ["a, b=>say \"hi\"", "x=>line1\nline2"])
    }

    @Test("CSV with CRLF and CR endings, and a BOM")
    func lineEndings() {
        #expect(pairs(ReplacementList.parse("\u{FEFF}a,b\r\nc,d\r\n", fileExtension: "csv")) == ["a=>b", "c=>d"])
        #expect(pairs(ReplacementList.parse("a,b\rc,d\r", fileExtension: "csv")) == ["a=>b", "c=>d"])
    }

    @Test("TSV splits on tabs")
    func tsv() {
        #expect(pairs(ReplacementList.parse("a b\tc d\ne\tf", fileExtension: "tsv")) == ["a b=>c d", "e=>f"])
    }

    @Test("arrow and equals lines")
    func arrows() {
        let text = "a → b\nc -> d\ne => f\ng = h\n"
        #expect(pairs(ReplacementList.parse(text, fileExtension: "txt")) == ["a=>b", "c=>d", "e=>f", "g=>h"])
    }

    @Test("a = b = c splits on the first separator")
    func firstSeparator() {
        #expect(pairs(ReplacementList.parse("a = b = c", fileExtension: "txt")) == ["a=>b = c"])
    }

    @Test("header rows are skipped without counting")
    func header() {
        #expect(ReplacementList.parse("Find,Replace\na,b", fileExtension: "csv").skippedLines == 0)
        #expect(pairs(ReplacementList.parse("Trova\tSostituisci\na\tb", fileExtension: "tsv")) == ["a=>b"])
        #expect(ReplacementList.parse("Trova,Sostituisci\na,b", fileExtension: "csv").skippedLines == 0)
    }

    @Test("comments, blanks, lines without a separator and empty finds are skipped and counted")
    func skipped() {
        let text = "# note\n\nnothing here\n → x\ngood → ok\n"
        let list = ReplacementList.parse(text, fileExtension: "txt")
        #expect(pairs(list) == ["good=>ok"])
        #expect(list.skippedLines == 4)
    }

    @Test("duplicates inside the file keep the first")
    func duplicates() {
        let list = ReplacementList.parse("a,b\na,c\n", fileExtension: "csv")
        #expect(pairs(list) == ["a=>b"])
        #expect(list.skippedLines == 1)
    }

    @Test("an empty replacement is a deletion rule")
    func deletion() {
        #expect(pairs(ReplacementList.parse("um,\nuh,\n", fileExtension: nil)) == ["um=>", "uh=>"])
        #expect(pairs(ReplacementList.parse("um →\nuh =>\n", fileExtension: nil)) == ["um=>", "uh=>"])
    }

    @Test("an unknown extension sniffs tabs, then arrows, then commas")
    func sniffing() {
        #expect(pairs(ReplacementList.parse("a\tb", fileExtension: "list")) == ["a=>b"])
        #expect(pairs(ReplacementList.parse("a -> b, c", fileExtension: nil)) == ["a=>b, c"])
        #expect(pairs(ReplacementList.parse("a,b", fileExtension: "txt")) == ["a=>b"])
    }

    @Test("an empty file yields nothing")
    func empty() {
        let list = ReplacementList.parse("", fileExtension: "csv")
        #expect(list.rules.isEmpty && list.skippedLines == 0)
    }

    @Test("a header with extra or empty columns is still a header")
    func headerWithMoreColumns() {
        #expect(pairs(ReplacementList.parse("find,replace,notes\ncat,dog,pet\n", fileExtension: "csv")) == ["cat=>dog"])
        #expect(pairs(ReplacementList.parse("Find,Replace,\ncat,dog,\n", fileExtension: "csv")) == ["cat=>dog"])
        #expect(pairs(ReplacementList.parse("find\treplace\tnotes\ncat\tdog\tpet\n", fileExtension: "tsv")) == ["cat=>dog"])
    }

    @Test("a header after a comment is still a header")
    func headerAfterComment() {
        let list = ReplacementList.parse("# my list\nfind,replace\ncat,dog\n", fileExtension: "csv")
        #expect(pairs(list) == ["cat=>dog"])
        #expect(list.skippedLines == 1)
    }

    @Test("an arrow header is skipped")
    func arrowHeader() {
        #expect(pairs(ReplacementList.parse("find → replace\ncat → dog", fileExtension: "txt")) == ["cat=>dog"])
        #expect(pairs(ReplacementList.parse("trova -> sostituisci\ncat -> dog", fileExtension: "txt")) == ["cat=>dog"])
    }

    @Test("a semicolon CSV splits on semicolons")
    func semicolons() {
        let list = ReplacementList.parse("trova;sostituisci\ncat;dog\n\"a; b\";\"x \"\"y\"\"\"\n", fileExtension: "csv")
        #expect(pairs(list) == ["cat=>dog", "a; b=>x \"y\""])
        #expect(list.skippedLines == 0)
    }

    @Test("a comma CSV with an occasional semicolon in a value stays on commas")
    func commaCSVWithSemicolonValue() {
        #expect(pairs(ReplacementList.parse("a,b;c\nd,e\n", fileExtension: "csv")) == ["a=>b;c", "d=>e"])
    }

    @Test("decimal commas with semicolon separators split on semicolons")
    func decimalCommas() {
        #expect(pairs(ReplacementList.parse("1,5;2,5\n3,5;4\n", fileExtension: "csv")) == ["1,5=>2,5", "3,5=>4"])
    }

    @Test("an unterminated quote skips its line and keeps the rest")
    func unterminatedQuote() {
        let list = ReplacementList.parse("cat,dog\n\"foo,bar\nx,y\nz,w\n", fileExtension: "csv")
        #expect(pairs(list) == ["cat=>dog", "x=>y", "z=>w"])
        #expect(list.skippedLines == 1)
    }

    @Test("a comment is a comment before any quote opens")
    func commentWithQuote() {
        let list = ReplacementList.parse("#,\"note\na,b\nc,d\n", fileExtension: "csv")
        #expect(pairs(list) == ["a=>b", "c=>d"])
        #expect(list.skippedLines == 1)
    }

    @Test("a tab inside a comment does not make the file TSV")
    func tabInComment() {
        #expect(pairs(ReplacementList.parse("# notes:\tthese\ncat -> dog\n", fileExtension: "txt")) == ["cat=>dog"])
    }

    @Test("a space before an opening quote is allowed")
    func spaceBeforeQuote() {
        #expect(pairs(ReplacementList.parse("\"cat\", \"dog\"\n", fileExtension: "csv")) == ["cat=>dog"])
    }

    @Test("duplicates are compared without case")
    func caseFoldedDuplicates() {
        let list = ReplacementList.parse("Cat,dog\ncat,cow\n", fileExtension: "csv")
        #expect(pairs(list) == ["Cat=>dog"])
        #expect(list.skippedLines == 1)
    }
}
