import Foundation

public struct SubtitleOptions: Sendable, Codable, Hashable {
    public var includeSpeakers: Bool
    public var captionLength: CaptionLength

    public init(includeSpeakers: Bool = false, captionLength: CaptionLength = .none) {
        self.includeSpeakers = includeSpeakers
        self.captionLength = captionLength
    }

    private enum CodingKeys: String, CodingKey {
        case includeSpeakers, captionLength
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeSpeakers = try c.decodeIfPresent(Bool.self, forKey: .includeSpeakers) ?? false
        captionLength = try c.decodeIfPresent(CaptionLength.self, forKey: .captionLength) ?? .none
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
            let body = CaptionWrapper.wrap(seg.text, length: options.captionLength)
            if options.includeSpeakers, let speaker = cueSpeakerLabel(seg.speaker) {
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
            let body = Format.escapeWebVTT(CaptionWrapper.wrap(seg.text, length: options.captionLength))
            if options.includeSpeakers, let speaker = cueSpeakerLabel(seg.speaker) {
                out += "<v \(Format.escapeWebVTT(speaker))>\(body)</v>\n\n"
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

// A speaker label sits on the cue's first line, so a newline in it would split the cue.
private func cueSpeakerLabel(_ speaker: String?) -> String? {
    guard let speaker else { return nil }
    let flattened = speaker.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flattened.isEmpty ? nil : flattened
}
