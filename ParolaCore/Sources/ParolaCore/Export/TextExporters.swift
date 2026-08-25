import Foundation

public struct TxtOptions: Sendable, Codable, Hashable {
    public var showTimestamps: Bool

    public init(showTimestamps: Bool = false) {
        self.showTimestamps = showTimestamps
    }
}

public struct TxtExporter: TranscriptExporter {
    public let format: ExportFormat = .txt
    public let options: TxtOptions

    public init(options: TxtOptions = TxtOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> Data {
        let lines = transcript.segments
            .compactMap { seg -> String? in
                let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let line: String
                if let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                    line = "\(speaker): \(body)"
                } else {
                    line = body
                }
                guard options.showTimestamps else { return line }
                return "[\(Format.timestampHHMMSS(seg.start))] \(line)"
            }
        guard !lines.isEmpty else { return Data() }
        return utf8(lines.joined(separator: "\n") + "\n")
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
        var out = "# \(Format.documentTitle(for: transcript))\n\n"
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
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let speaker = Self.escape(Format.presentationSpeakerLabel(seg.speaker) ?? "")
            let text = Self.escape(trimmed)
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
