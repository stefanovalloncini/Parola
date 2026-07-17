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
        var cueNumber = 1
        for seg in transcript.segments {
            let body = CaptionWrapper.wrap(seg.text, length: options.captionLength)
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(cueNumber)\n"
            out += "\(Self.srtTimestamp(seg.start)) --> \(Self.srtTimestamp(end))\n"
            if options.includeSpeakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                out += "\(speaker): \(body)\n\n"
            } else {
                out += body + "\n\n"
            }
            cueNumber += 1
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
            let body = Format.escapeWebVTT(CaptionWrapper.wrap(seg.text, length: options.captionLength))
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(Self.vttTimestamp(seg.start)) --> \(Self.vttTimestamp(end))\n"
            if options.includeSpeakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
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
