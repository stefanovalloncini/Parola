import Foundation

struct TxtExporter: TranscriptExporter {
    let format: ExportFormat = .txt
    init() {}
    func render(_ transcript: Transcript) throws -> Data {
        let text = transcript.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return utf8(text)
    }
}

public struct MarkdownOptions: Sendable, Codable, Hashable {
    public var showTimestamps: Bool

    public init(showTimestamps: Bool = false) {
        self.showTimestamps = showTimestamps
    }
}

public struct MarkdownExporter: TranscriptExporter {
    public let format: ExportFormat = .md
    public let options: MarkdownOptions

    public init(options: MarkdownOptions = MarkdownOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> Data {
        var out = ""
        for seg in transcript.segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let label = Format.presentationSpeakerLabel(seg.speaker)
            switch (label, options.showTimestamps) {
            case (let speaker?, true):
                out += "**\(speaker)** *[\(Format.timestampHHMMSS(seg.start))]*: \(body)\n\n"
            case (let speaker?, false):
                out += "**\(speaker):** \(body)\n\n"
            case (nil, true):
                out += "*[\(Format.timestampHHMMSS(seg.start))]* \(body)\n\n"
            case (nil, false):
                out += "\(body)\n\n"
            }
        }
        return utf8(String(out.dropLast()))
    }
}

struct TsvExporter: TranscriptExporter {
    let format: ExportFormat = .tsv
    init() {}

    func render(_ transcript: Transcript) throws -> Data {
        var out = "start_seconds\tend_seconds\tspeaker\ttext\n"
        for seg in transcript.segments {
            let speaker = Self.escape(Format.presentationSpeakerLabel(seg.speaker) ?? "")
            let text = Self.escape(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
            out += "\(Format.decimalSeconds(seg.start))\t\(Format.decimalSeconds(seg.end))\t\(speaker)\t\(text)\n"
        }
        return utf8(out)
    }

    static func escape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
