import Foundation

public struct ExportPreset: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var formats: [ExportFormat]
    public var markdownOptions: MarkdownOptions?
    public var subtitleOptions: SubtitleOptions?

    public init(
        id: UUID = UUID(),
        name: String,
        formats: [ExportFormat],
        markdownOptions: MarkdownOptions? = nil,
        subtitleOptions: SubtitleOptions? = nil
    ) {
        self.id = id
        self.name = name
        self.formats = formats
        self.markdownOptions = markdownOptions
        self.subtitleOptions = subtitleOptions
    }

    public func exporter(for format: ExportFormat) -> TranscriptExporter? {
        guard formats.contains(format) else { return nil }
        switch format {
        case .md:
            return MarkdownExporter(options: markdownOptions ?? MarkdownOptions())
        case .srt:
            return SrtExporter(options: subtitleOptions ?? SubtitleOptions())
        case .vtt:
            return VttExporter(options: subtitleOptions ?? SubtitleOptions())
        default:
            return Exporters.exporter(for: format)
        }
    }
}
