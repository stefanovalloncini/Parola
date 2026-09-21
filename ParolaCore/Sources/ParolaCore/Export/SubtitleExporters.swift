import Foundation

public struct SrtExporter: TranscriptExporter {
    public let format: ExportFormat = .srt
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .srt)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        var out = ""
        var cueNumber = 1
        for seg in transcript.segments {
            let body = CaptionWrapper.wrap(seg.text, length: options.captionLength)
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(cueNumber)\n"
            out += "\(Self.srtTimestamp(seg.start)) --> \(Self.srtTimestamp(end))\n"
            let tail = translation(for: seg, in: transcript)
                .map { "\n" + CaptionWrapper.wrap($0, length: options.captionLength) } ?? ""
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                out += "\(speaker): \(body)\(tail)\n\n"
            } else {
                out += body + tail + "\n\n"
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
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .vtt)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        var out = "WEBVTT\n\n"
        for seg in transcript.segments {
            let body = Format.escapeWebVTT(CaptionWrapper.wrap(seg.text, length: options.captionLength))
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(Self.vttTimestamp(seg.start)) --> \(Self.vttTimestamp(end))\n"
            let tail = translation(for: seg, in: transcript)
                .map { "\n" + Format.escapeWebVTT(CaptionWrapper.wrap($0, length: options.captionLength)) } ?? ""
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                out += "<v \(Format.escapeWebVTT(speaker))>\(body)\(tail)</v>\n\n"
            } else {
                out += body + tail + "\n\n"
            }
        }
        return utf8(out)
    }

    static func vttTimestamp(_ seconds: Double) -> String {
        Format.subtitleTimestamp(seconds, msSeparator: ".")
    }
}
