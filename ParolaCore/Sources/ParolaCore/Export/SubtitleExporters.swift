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
        let clamped = max(0, seconds)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
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
        let clamped = max(0, seconds)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
