import Foundation

public struct TxtExporter: TranscriptExporter {
    public let format: ExportFormat = .txt
    public init() {}
    public func render(_ transcript: Transcript) throws -> Data {
        let text = transcript.segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return utf8(text)
    }
}

public struct MarkdownOptions: Sendable {
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
            let body = seg.text.trimmingCharacters(in: .whitespaces)
            switch (seg.speaker, options.showTimestamps) {
            case (let speaker?, true):
                out += "**\(speaker)** *[\(Self.timestamp(seg.start))]*: \(body)\n\n"
            case (let speaker?, false):
                out += "**\(speaker):** \(body)\n\n"
            case (nil, true):
                out += "*[\(Self.timestamp(seg.start))]* \(body)\n\n"
            case (nil, false):
                out += "\(body)\n\n"
            }
        }
        return utf8(String(out.dropLast()))
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
