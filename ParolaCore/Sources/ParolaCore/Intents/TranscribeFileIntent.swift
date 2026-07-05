import AppIntents
import Foundation

public struct TranscribeFileIntent: AppIntent {
    public static let title: LocalizedStringResource = "Transcribe File"
    public static let description = IntentDescription("Transcribes an audio or video file in Parola with your current model and language settings, and returns the transcript text.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.audiovisual-content"])
    public var file: IntentFile

    public static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$file)")
    }

    public init() {}

    public init(file: IntentFile) {
        self.file = file
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let transcribeFile = IntentPerformers.transcribeFile else {
            throw ParolaIntentError.unavailable
        }
        let source = try Self.materialize(file)
        defer { if source.scoped { source.url.stopAccessingSecurityScopedResource() } }
        return .result(value: try await transcribeFile(source.url))
    }

    static func materialize(_ file: IntentFile) throws -> (url: URL, scoped: Bool) {
        if let url = file.fileURL {
            return (url, url.startAccessingSecurityScopedResource())
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.filename)
        try file.data.write(to: url)
        return (url, false)
    }
}
