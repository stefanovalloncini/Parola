import Foundation

/// A plain list of replacements (CSV, TSV or one `find → replace` per line), parsed into whole-word term pack rules.
public struct ReplacementList: Sendable, Hashable {
    public var rules: [TermPackRule]
    public var skippedLines: Int

    public init(rules: [TermPackRule], skippedLines: Int) {
        self.rules = rules
        self.skippedLines = skippedLines
    }

    private enum Format {
        case csv, tsv, arrow
    }

    private static let arrowSeparators = ["→", "->", "=>", "="]
    private static let headerNames: [(find: String, replace: String)] = [("find", "replace"), ("trova", "sostituisci")]

    private struct Record {
        var cells: [String]
        var isMalformed = false
    }

    public static func parse(_ text: String, fileExtension: String?) -> ReplacementList {
        var body = Substring(text)
        if body.unicodeScalars.first == "\u{FEFF}" { body = body.dropFirst() }
        let format = format(for: body, fileExtension: fileExtension)
        var records: [Record]
        switch format {
        case .csv: records = csvRecords(String(body), delimiter: csvDelimiter(for: body))
        case .tsv, .arrow: records = lines(of: String(body)).map { Record(cells: [$0]) }
        }
        if let last = records.last, !last.isMalformed, isBlank(last.cells) { records.removeLast() }

        var rules: [TermPackRule] = []
        var seen = Set<String>()
        var skipped = 0
        var headerChecked = false
        for record in records {
            let cells: [String]
            switch format {
            case .csv: cells = record.cells
            case .tsv: cells = record.cells[0].components(separatedBy: "\t")
            case .arrow: cells = splitOnArrow(record.cells[0]).map { [$0.0, $0.1] } ?? [record.cells[0]]
            }
            let first = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.isMalformed, !isBlank(cells), !first.hasPrefix("#") else {
                skipped += 1
                continue
            }
            if !headerChecked {
                headerChecked = true
                if isHeader(cells) { continue }
            }
            guard cells.count >= 2, !first.isEmpty,
                  seen.insert(first.folding(options: .caseInsensitive, locale: nil)).inserted
            else {
                skipped += 1
                continue
            }
            let replace = cells[1].trimmingCharacters(in: .whitespacesAndNewlines)
            rules.append(TermPackRule(find: first, replace: replace, wholeWord: true))
        }
        return ReplacementList(rules: rules, skippedLines: skipped)
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    private static func format(for text: Substring, fileExtension: String?) -> Format {
        switch fileExtension?.lowercased() {
        case "csv": return .csv
        case "tsv": return .tsv
        default: break
        }
        let content = lines(of: String(text)).filter { !isComment($0) }
        if content.contains(where: { $0.contains("\t") }) { return .tsv }
        if content.contains(where: { line in arrowSeparators.contains { line.contains($0) } }) { return .arrow }
        return text.contains(",") ? .csv : .arrow
    }

    /// Excel in a region that writes decimal commas saves `;`-separated CSV.
    private static func csvDelimiter(for text: Substring) -> Unicode.Scalar {
        let content = lines(of: String(text)).filter { !isComment($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let everyLineHasSemicolon = !content.isEmpty && content.allSatisfy { unquoted($0).contains(";") }
        return everyLineHasSemicolon ? ";" : ","
    }

    private static func unquoted(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        var inQuotes = false
        for scalar in line.unicodeScalars {
            if scalar == "\"" { inQuotes.toggle() } else if !inQuotes { out.append(scalar) }
        }
        return String(out)
    }

    private static func isBlank(_ cells: [String]) -> Bool {
        cells.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func isHeader(_ cells: [String]) -> Bool {
        guard cells.count >= 2 else { return false }
        let pair = (cells[0].trimmingCharacters(in: .whitespaces).lowercased(), cells[1].trimmingCharacters(in: .whitespaces).lowercased())
        return headerNames.contains { $0.find == pair.0 && $0.replace == pair.1 }
    }

    private static func lines(of text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            if scalar == "\n" || scalar == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        out.append(String(current))
        return out
    }

    /// Splits at the earliest separator; where "=>" and "=" start together the longer one wins.
    private static func splitOnArrow(_ line: String) -> (String, String)? {
        var best: Range<String.Index>?
        for separator in arrowSeparators {
            guard let range = line.range(of: separator) else { continue }
            if let current = best {
                if range.lowerBound < current.lowerBound
                    || (range.lowerBound == current.lowerBound && line.distance(from: range.lowerBound, to: range.upperBound) > line.distance(from: current.lowerBound, to: current.upperBound)) {
                    best = range
                }
            } else {
                best = range
            }
        }
        guard let range = best else { return nil }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    /// An unterminated quote marks its own line as malformed; parsing resumes on the next line.
    private static func csvRecords(_ text: String, delimiter: Unicode.Scalar) -> [Record] {
        var records: [Record] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var justClosedQuote = false
        var previousWasCR = false
        let scalars = Array(text.unicodeScalars)
        var recordStart = 0
        var i = 0
        func isBlankField(_ view: String.UnicodeScalarView) -> Bool {
            view.allSatisfy { $0.properties.isWhitespace }
        }
        while i < scalars.count {
            let scalar = scalars[i]
            defer { i += 1 }
            if inQuotes {
                if scalar == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                        justClosedQuote = true
                    }
                } else {
                    field.append(scalar)
                }
                continue
            }
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                recordStart = i + 1
                continue
            }
            previousWasCR = scalar == "\r"
            let atRecordStart = record.isEmpty && field.isEmpty && i == recordStart
            if scalar == "#", atRecordStart {
                var comment = String.UnicodeScalarView()
                while i < scalars.count, scalars[i] != "\n", scalars[i] != "\r" {
                    comment.append(scalars[i])
                    i += 1
                }
                records.append(Record(cells: [String(comment)]))
                if i + 1 < scalars.count, scalars[i] == "\r", scalars[i + 1] == "\n" { i += 1 }
                recordStart = i + 1
                continue
            }
            switch scalar {
            case "\"" where isBlankField(field) && !justClosedQuote:
                field = String.UnicodeScalarView()
                inQuotes = true
            case delimiter:
                record.append(String(field))
                field = String.UnicodeScalarView()
                justClosedQuote = false
            case "\n", "\r":
                record.append(String(field))
                records.append(Record(cells: record))
                record = []
                field = String.UnicodeScalarView()
                justClosedQuote = false
                recordStart = i + 1
            default:
                field.append(scalar)
            }
        }
        if inQuotes {
            let rest = String(String.UnicodeScalarView(scalars[recordStart...]))
            let afterBadLine = lines(of: rest).dropFirst().joined(separator: "\n")
            records.append(Record(cells: [""], isMalformed: true))
            records += csvRecords(afterBadLine, delimiter: delimiter)
            return records
        }
        record.append(String(field))
        records.append(Record(cells: record))
        return records
    }
}
