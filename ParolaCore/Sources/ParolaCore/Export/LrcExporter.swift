import Foundation

/// Renders the transcript as plain LRC lyrics: one `[mm:ss.xx]` line per segment.
public struct LrcExporter: TranscriptExporter {
    public let format: ExportFormat = .lrc

    public init() {}

    public func render(_ transcript: Transcript) throws -> Data {
        var out = ""
        for seg in transcript.segments {
            let body = seg.text
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out += "[\(Self.lrcTimestamp(seg.start))]\(body)\n"
        }
        return utf8(out)
    }

    static func lrcTimestamp(_ seconds: Double) -> String {
        let total = Int(exactly: (max(0, seconds) * 100).rounded()) ?? .max
        let cs = total % 100
        let s = (total / 100) % 60
        let m = total / 6000
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}
