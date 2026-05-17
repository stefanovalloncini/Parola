import Foundation

public struct SubtitleOptions: Sendable, Codable, Hashable {
    public var includeSpeakers: Bool

    public init(includeSpeakers: Bool = false) {
        self.includeSpeakers = includeSpeakers
    }
}

public struct SrtExporter: TranscriptExporter {
    public let format: ExportFormat = .srt
    public let options: SubtitleOptions

    public init(options: SubtitleOptions = SubtitleOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> Data {
        var out = ""
        for (i, seg) in transcript.segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(Self.srtTimestamp(seg.start)) --> \(Self.srtTimestamp(seg.end))\n"
            let body = seg.text.trimmingCharacters(in: .whitespaces)
            if options.includeSpeakers, let speaker = seg.speaker, !speaker.isEmpty {
                out += "\(speaker): \(body)\n\n"
            } else {
                out += body + "\n\n"
            }
        }
        return utf8(out)
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        Format.subtitleTimestamp(seconds, msSeparator: ",")
    }
}

public struct VttExporter: TranscriptExporter {
    public let format: ExportFormat = .vtt
    public let options: SubtitleOptions

    public init(options: SubtitleOptions = SubtitleOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> Data {
        var out = "WEBVTT\n\n"
        for seg in transcript.segments {
            out += "\(Self.vttTimestamp(seg.start)) --> \(Self.vttTimestamp(seg.end))\n"
            let body = seg.text.trimmingCharacters(in: .whitespaces)
            if options.includeSpeakers, let speaker = seg.speaker, !speaker.isEmpty {
                out += "<v \(speaker)>\(body)</v>\n\n"
            } else {
                out += body + "\n\n"
            }
        }
        return utf8(out)
    }

    static func vttTimestamp(_ seconds: Double) -> String {
        Format.subtitleTimestamp(seconds, msSeparator: ".")
    }
}
