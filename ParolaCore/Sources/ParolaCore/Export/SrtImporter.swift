import Foundation

/// Parses SubRip (.srt) subtitle files into a ``Transcript``.
public enum SrtImporter {
    public static func parse(contentsOf url: URL) throws -> Transcript {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return parse(raw)
    }

    public static func parse(_ raw: String) -> Transcript {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var segments: [TranscriptSegment] = []
        var i = 0
        var nextID = 0
        while i < lines.count {
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            }
            guard i < lines.count else { break }

            if Int(lines[i].trimmingCharacters(in: .whitespaces)) != nil { i += 1 }
            guard i < lines.count, let times = parseTimeLine(lines[i]) else {
                i += 1
                continue
            }
            i += 1

            var textLines: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[i])
                i += 1
            }

            segments.append(TranscriptSegment(
                id: nextID,
                start: times.start,
                end: times.end,
                text: textLines.joined(separator: " ")
            ))
            nextID += 1
        }

        return Transcript(
            segments: segments,
            language: "unknown",
            modelName: "imported-srt",
            durationSeconds: segments.last?.end
        )
    }

    static func parseTimeLine(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1])
        else { return nil }
        return (start, end)
    }

    static func parseTimestamp(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let sec = Double(parts[2])
        else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + sec
    }
}
