import Foundation

/// The page a transcript becomes in Notion, as the block JSON the API takes.
public enum NotionBlocks {
    public static let maxRunLength = 2000
    public static let maxBlocksPerRequest = 100
    /// A transcript paragraph grows to about this many characters before the next one starts.
    static let paragraphTarget = 1000
    static let maxRunsPerBlock = 50

    public static func blocks(for payload: DeliveryPayload, headings: NotionHeadings = NotionHeadings()) -> [DestinationConfig] {
        var blocks: [DestinationConfig] = []
        func heading(_ text: String) {
            blocks.append(block("heading_2", ["rich_text": .array(richText(text))]))
        }
        if let summary = payload.summary {
            let paragraphs = summary.text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !paragraphs.isEmpty {
                heading(headings.summary)
                for paragraph in paragraphs {
                    blocks.append(contentsOf: textBlocks(type: "paragraph", runs: richText(paragraph)))
                }
            }
            let items = summary.actionItems.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !items.isEmpty {
                heading(headings.actionItems)
                for item in items {
                    blocks.append(block("to_do", ["rich_text": .array(richText(item)), "checked": .bool(false)]))
                }
            }
            if !summary.chapters.isEmpty {
                heading(headings.chapters)
                for chapter in summary.chapters {
                    let line = "\(Timecode.format(chapter.start)) \(chapter.title)"
                    blocks.append(contentsOf: textBlocks(type: "bulleted_list_item", runs: richText(line)))
                }
            }
        }
        let turns = transcriptTurns(payload.transcript)
        if !turns.isEmpty {
            heading(headings.transcript)
            for turn in turns {
                var runs: [DestinationConfig] = []
                if let speaker = turn.speaker { runs.append(run(speaker + " ", bold: true)) }
                runs.append(contentsOf: richText(turn.text))
                blocks.append(contentsOf: textBlocks(type: "paragraph", runs: runs))
            }
        }
        return blocks
    }

    /// Runs of at most `limit` UTF-16 units that join back into the text exactly, each cut after a space
    /// where there is one and between characters otherwise.
    public static func chunks(_ text: String, limit: Int = maxRunLength) -> [String] {
        guard text.utf16.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var current: [Character] = []
        var units = 0
        var breakAfter: Int?
        for character in text {
            let size = character.utf16.count
            if size > limit {
                if !current.isEmpty { result.append(String(current)) }
                current = []
                units = 0
                breakAfter = nil
                result.append(contentsOf: scalarPieces(of: character, limit: limit))
                continue
            }
            while units + size > limit {
                let cut = breakAfter ?? current.count
                result.append(String(current[..<cut]))
                current = Array(current[cut...])
                units = current.reduce(0) { $0 + $1.utf16.count }
                breakAfter = nil
            }
            current.append(character)
            units += size
            if character.isWhitespace { breakAfter = current.count }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    private static func scalarPieces(of character: Character, limit: Int) -> [String] {
        var pieces: [String] = []
        var piece = String.UnicodeScalarView()
        var units = 0
        for scalar in character.unicodeScalars {
            let size = scalar.utf16.count
            if units + size > limit {
                pieces.append(String(piece))
                piece = String.UnicodeScalarView()
                units = 0
            }
            piece.append(scalar)
            units += size
        }
        if !piece.isEmpty { pieces.append(String(piece)) }
        return pieces
    }

    static func richText(_ text: String, bold: Bool = false) -> [DestinationConfig] {
        chunks(text).map { run($0, bold: bold) }
    }

    static func run(_ text: String, bold: Bool = false) -> DestinationConfig {
        var fields: [String: DestinationConfig] = [
            "type": .string("text"),
            "text": .object(["content": .string(text)]),
        ]
        if bold { fields["annotations"] = .object(["bold": .bool(true)]) }
        return .object(fields)
    }

    static func block(_ type: String, _ content: [String: DestinationConfig]) -> DestinationConfig {
        .object(["object": .string("block"), "type": .string(type), type: .object(content)])
    }

    /// One block, or several when a single block would carry more runs than Notion takes.
    private static func textBlocks(type: String, runs: [DestinationConfig]) -> [DestinationConfig] {
        stride(from: 0, to: runs.count, by: maxRunsPerBlock).map { start in
            block(type, ["rich_text": .array(Array(runs[start..<min(start + maxRunsPerBlock, runs.count)]))])
        }
    }

    struct Turn: Equatable {
        var speaker: String?
        var text: String
    }

    static func transcriptTurns(_ transcript: Transcript) -> [Turn] {
        var turns: [Turn] = []
        var previousSpeaker: String??
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let sameSpeaker = previousSpeaker.map { $0 == speaker } ?? false
            if sameSpeaker, let last = turns.last, last.text.count < paragraphTarget {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: sameSpeaker ? nil : speaker, text: text))
            }
            previousSpeaker = .some(speaker)
        }
        return turns
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum NotionPageID {
    /// The 32 hex digits in a pasted page link or ID, as a dashed lowercase UUID.
    public static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidates: [String] = []
        if let components = URLComponents(string: trimmed), components.host != nil {
            if let pageParam = components.queryItems?.first(where: { $0.name == "p" })?.value { candidates.append(pageParam) }
            candidates.append((components.path as NSString).lastPathComponent)
        } else {
            candidates.append(trimmed)
        }
        for candidate in candidates {
            let hex = candidate.replacingOccurrences(of: "-", with: "")
            guard hex.count >= 32 else { continue }
            let tail = String(hex.suffix(32))
            guard tail.allSatisfy(\.isHexDigit), tail.allSatisfy(\.isASCII) else { continue }
            let lower = tail.lowercased()
            let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range -> String in
                let start = lower.index(lower.startIndex, offsetBy: range.lowerBound)
                let end = lower.index(lower.startIndex, offsetBy: range.upperBound)
                return String(lower[start..<end])
            }
            return parts.joined(separator: "-")
        }
        return nil
    }
}
