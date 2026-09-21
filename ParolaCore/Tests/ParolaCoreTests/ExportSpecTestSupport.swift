import Foundation
@testable import ParolaCore

extension ExportSpec {
    static func txt(timestamps: Bool = false, speakers: Bool = true) -> ExportSpec {
        var spec = ExportSpec.standard(for: .txt)
        spec.options.timestamps = timestamps
        spec.options.speakers = speakers
        return spec
    }

    static func md(timestamps: Bool = false, speakers: Bool = true) -> ExportSpec {
        var spec = ExportSpec.standard(for: .md)
        spec.options.timestamps = timestamps
        spec.options.speakers = speakers
        return spec
    }

    static func html(timestamps: Bool = true, theme: HtmlExportTheme = .light) -> ExportSpec {
        var spec = ExportSpec.standard(for: .html)
        spec.options.timestamps = timestamps
        spec.options.htmlTheme = theme
        return spec
    }

    static func srt(speakers: Bool = false, captionLength: CaptionLength = .none) -> ExportSpec {
        var spec = ExportSpec.standard(for: .srt)
        spec.options.speakers = speakers
        spec.options.captionLength = captionLength
        return spec
    }

    static func vtt(speakers: Bool = false, captionLength: CaptionLength = .none) -> ExportSpec {
        var spec = ExportSpec.standard(for: .vtt)
        spec.options.speakers = speakers
        spec.options.captionLength = captionLength
        return spec
    }
}
