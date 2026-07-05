import Foundation

/// Renders the transcript as an FCPXML 1.9 project whose captions sit on a lane
/// over a single gap, ready for File > Import > XML in Final Cut Pro.
public struct FcpxmlExporter: TranscriptExporter {
    public let format: ExportFormat = .fcpxml

    public init() {}

    public func render(_ transcript: Transcript) throws -> Data {
        let title = Format.escapeXML(Format.documentTitle(for: transcript))
        let role = "iTT?captionFormat=ITT.\(Self.captionLanguage(transcript.language))"
        let lastEnd = transcript.segments.map(\.end).max() ?? 0
        // FCP refuses a zero-length gap, so an empty transcript still spans one second.
        let total = Self.rationalTime(max(transcript.durationSeconds ?? 0, lastEnd, 1))

        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
            <resources>
                <format id="r1" name="FFVideoFormat1080p30" frameDuration="100/3000s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
            </resources>
            <library>
                <event name="Parola">
                    <project name="\(title)">
                        <sequence format="r1" duration="\(total)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
                                <gap name="Gap" offset="0s" start="0s" duration="\(total)">

        """
        var styleNumber = 1
        for seg in transcript.segments {
            let body = Format.escapeXML(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !body.isEmpty else { continue }
            let offset = Self.rationalTime(seg.start)
            let duration = Self.rationalTime(seg.end - seg.start)
            out += """
                                        <caption lane="1" offset="\(offset)" start="0s" duration="\(duration)" role="\(role)">
                                            <text placement="bottom"><text-style ref="ts\(styleNumber)">\(body)</text-style></text>
                                            <text-style-def id="ts\(styleNumber)">
                                                <text-style font=".SF NS Text" fontSize="13" fontFace="Regular" fontColor="1 1 1 1" backgroundColor="0 0 0 1"/>
                                            </text-style-def>
                                        </caption>

            """
            styleNumber += 1
        }
        out += """
                                </gap>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
        return utf8(out)
    }

    static func rationalTime(_ seconds: Double) -> String {
        let n = Int(exactly: (max(0, seconds) * 30000).rounded()) ?? .max
        return "\(n)/30000s"
    }

    // The role's subrole must be a language code Final Cut recognises; "en" covers
    // empty/"unknown" detection results without blocking the import.
    static func captionLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCode = (2...8).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }
        return isCode && trimmed != "unknown" ? trimmed : "en"
    }
}
