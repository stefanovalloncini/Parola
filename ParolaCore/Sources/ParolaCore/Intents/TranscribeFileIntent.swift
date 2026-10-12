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
        let source = try await Self.materialize(file)
        defer { source.stopAccess() }
        let text = try await transcribeFile(source.url)
        source.removeScratch()
        return .result(value: text)
    }

    /// A file this intent wrote for a Shortcut that passed data: it goes once a run has succeeded, so nothing may keep pointing at it by then.
    public static func isIntentScratch(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        return folder.lastPathComponent.hasPrefix("parola-intent-")
            && folder.deletingLastPathComponent().resolvingSymlinksInPath().path
            == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    }

    struct Materialized: Sendable {
        let url: URL
        let scoped: Bool
        let scratchDirectory: URL?

        func release() {
            stopAccess()
            removeScratch()
        }

        func stopAccess() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        /// Only after a run succeeds: a failed run's Retry, Reveal and player still point at the file.
        func removeScratch() {
            guard let scratchDirectory else { return }
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
    }

    static func materialize(_ file: IntentFile) async throws -> Materialized {
        if let url = file.fileURL {
            return Materialized(url: url, scoped: url.startAccessingSecurityScopedResource(), scratchDirectory: nil)
        }
        let data = file.data
        let filename = file.filename
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("parola-intent-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent(filename)
                    try data.write(to: url)
                    return Materialized(url: url, scoped: false, scratchDirectory: dir)
                })
            }
        }
    }
}
