import Foundation

public struct SrtExporter: TranscriptExporter {
    public let format: ExportFormat = .srt
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .srt)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        guard let limit = options.captionLength.maxCharsPerLine else { return utf8(asIs(transcript)) }
        let sources = CaptionCues.sources(prepared: transcript, spec: spec, grouped: false)
        return try written(sources, limit: limit)
    }

    public func render(_ transcript: Transcript) throws -> Data {
        guard let limit = options.captionLength.maxCharsPerLine else { return try encode(spec.prepared(transcript)) }
        return try written(CaptionCues.sources(from: transcript, spec: spec), limit: limit)
    }

    private func written(_ sources: [CaptionSource], limit: Int) throws -> Data {
        let cues = try CaptionCues.cues(for: sources, breaker: .characters(limit), speakerPrefix: { "\($0): " })
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(Self.srtTimestamp(cue.start)) --> \(Self.srtTimestamp(cue.end))\n"
            out += cue.shownLines(speakerPrefix: { "\($0): " }).joined(separator: "\n") + "\n\n"
        }
        return utf8(out)
    }

    private func asIs(_ transcript: Transcript) -> String {
        var out = ""
        var cueNumber = 1
        for seg in transcript.segments {
            let body = CaptionWrapper.asIs(seg.text)
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(cueNumber)\n"
            out += "\(Self.srtTimestamp(seg.start)) --> \(Self.srtTimestamp(end))\n"
            let tail = translation(for: seg, in: transcript)
                .map { "\n" + CaptionWrapper.asIs($0) } ?? ""
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                out += "\(speaker): \(body)\(tail)\n\n"
            } else {
                out += body + tail + "\n\n"
            }
            cueNumber += 1
        }
        return out
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
        guard let limit = options.captionLength.maxCharsPerLine else { return utf8(asIs(transcript)) }
        return try written(CaptionCues.sources(prepared: transcript, spec: spec, grouped: false), limit: limit)
    }

    public func render(_ transcript: Transcript) throws -> Data {
        guard let limit = options.captionLength.maxCharsPerLine else { return try encode(spec.prepared(transcript)) }
        return try written(CaptionCues.sources(from: transcript, spec: spec), limit: limit)
    }

    private func written(_ sources: [CaptionSource], limit: Int) throws -> Data {
        let cues = try CaptionCues.cues(for: sources, breaker: .characters(limit), speakerPrefix: { _ in "" })
        var out = "WEBVTT\n\n"
        for cue in cues {
            let body = Format.escapeWebVTT((cue.lines + cue.translation).joined(separator: "\n"))
            out += "\(Self.vttTimestamp(cue.start)) --> \(Self.vttTimestamp(cue.end))\n"
            if let speaker = cue.voice {
                out += "<v \(Format.escapeWebVTT(speaker))>\(body)</v>\n\n"
            } else {
                out += body + "\n\n"
            }
        }
        return utf8(out)
    }

    private func asIs(_ transcript: Transcript) -> String {
        var out = "WEBVTT\n\n"
        for seg in transcript.segments {
            let body = Format.escapeWebVTT(CaptionWrapper.asIs(seg.text))
            guard !body.isEmpty else { continue }
            let end = max(seg.end, seg.start + Format.minCaptionSeconds)
            out += "\(Self.vttTimestamp(seg.start)) --> \(Self.vttTimestamp(end))\n"
            let tail = translation(for: seg, in: transcript)
                .map { "\n" + Format.escapeWebVTT(CaptionWrapper.asIs($0)) } ?? ""
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                out += "<v \(Format.escapeWebVTT(speaker))>\(body)\(tail)</v>\n\n"
            } else {
                out += body + tail + "\n\n"
            }
        }
        return out
    }

    static func vttTimestamp(_ seconds: Double) -> String {
        Format.subtitleTimestamp(seconds, msSeparator: ".")
    }
}
