import Foundation

public struct TxtExporter: TranscriptExporter {
    public let format: ExportFormat = .txt
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .txt)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        let lines = transcript.segments
            .compactMap { seg -> String? in
                let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let line: String
                if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                    line = "\(speaker): \(body)"
                } else {
                    line = body
                }
                let stamped = options.timestampLabel(start: seg.start, end: seg.end)
                    .map { "[\($0)] \(line)" } ?? line
                guard let translated = translation(for: seg, in: transcript) else { return stamped }
                return "\(stamped)\n\(translated)"
            }
        guard !lines.isEmpty else { return Data() }
        return utf8(lines.joined(separator: "\n") + "\n")
    }
}

public struct MarkdownExporter: TranscriptExporter {
    public let format: ExportFormat = .md
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .md)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        var out = "# \(Format.documentTitle(for: transcript, options: options))\n\n"
        for seg in transcript.segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let label = options.speakers ? Format.presentationSpeakerLabel(seg.speaker) : nil
            // Two trailing spaces: the markdown line break that keeps both languages in one paragraph.
            let tail = translation(for: seg, in: transcript).map { "  \n\($0)" } ?? ""
            switch (label, options.timestampLabel(start: seg.start, end: seg.end)) {
            case (let speaker?, let stamp?):
                out += "**\(speaker)** *[\(stamp)]*: \(body)\(tail)\n\n"
            case (let speaker?, nil):
                out += "**\(speaker):** \(body)\(tail)\n\n"
            case (nil, let stamp?):
                out += "*[\(stamp)]* \(body)\(tail)\n\n"
            case (nil, nil):
                out += "\(body)\(tail)\n\n"
            }
        }
        return utf8(String(out.dropLast()))
    }
}

struct TsvExporter: TranscriptExporter {
    let format: ExportFormat = .tsv
    let spec: ExportSpec

    init(spec: ExportSpec = .standard(for: .tsv)) {
        self.spec = spec
    }

    func encode(_ transcript: Transcript) throws -> Data {
        let writesTranslation = spec.resolvedContent == .both
        var out = "start_seconds\tend_seconds\tspeaker\ttext"
        out += writesTranslation ? "\ttranslation\n" : "\n"
        for seg in transcript.segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let speaker = Self.escape(Format.presentationSpeakerLabel(seg.speaker) ?? "")
            let text = Self.escape(trimmed)
            out += "\(Format.decimalSeconds(seg.start))\t\(Format.decimalSeconds(seg.end))\t\(speaker)\t\(text)"
            if writesTranslation {
                out += "\t\(Self.escape(translation(for: seg, in: transcript) ?? ""))"
            }
            out += "\n"
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
