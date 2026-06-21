import Foundation

enum VttImporter {
    static func parse(contentsOf url: URL) throws -> Transcript {
        let data = try Data(contentsOf: url)
        let raw = String(decoding: data, as: UTF8.self)
        return parse(raw)
    }

    static func parse(_ raw: String) -> Transcript {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var segments: [TranscriptSegment] = []
        var i = 0
        var nextID = 0

        while i < lines.count,
              !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
              !lines[i].contains("-->") {
            i += 1
        }

        while i < lines.count {
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            }
            guard i < lines.count else { break }

            if isBlockKeyword(lines[i]) {
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }

            if !lines[i].contains("-->") {
                i += 1
            }
            guard i < lines.count, let times = parseTimeLine(lines[i]) else {
                i += 1
                continue
            }
            i += 1

            var textLines: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(stripInlineTags(lines[i]))
                i += 1
            }

            let text = decodeEntities(textLines.joined(separator: " "))
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    id: nextID,
                    start: times.start,
                    end: times.end,
                    text: text
                ))
                nextID += 1
            }
        }

        return Transcript(
            segments: segments,
            language: "unknown",
            modelName: "youtube-subs",
            durationSeconds: segments.last?.end
        )
    }

    static func isBlockKeyword(_ line: String) -> Bool {
        let prefix = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
        switch prefix.uppercased() {
        case "NOTE", "STYLE", "REGION":
            return true
        default:
            return false
        }
    }

    static func parseTimeLine(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startSide = parts[0].trimmingCharacters(in: .whitespaces)
        let endSide = parts[1].trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? parts[1]
        guard let start = parseTimestamp(startSide), let end = parseTimestamp(endSide) else {
            return nil
        }
        return (start, end)
    }

    static func parseTimestamp(_ s: String) -> Double? {
        Format.parseClockTimestamp(s)
    }

    // Must run after tag stripping, else an escaped `&lt;b&gt;` is eaten as a tag; `&amp;` last so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripInlineTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var inside = false
        for ch in line {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return out
    }
}
