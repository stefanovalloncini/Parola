import ArgumentParser
import Foundation
import ParolaCore

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio or video file."
    )

    @Argument(help: "Path to the audio/video file.")
    var input: String

    @Option(name: .shortAndLong, help: "Model variant (e.g. openai_whisper-tiny, openai_whisper-large-v3-turbo).")
    var model: String = "openai_whisper-tiny"

    @Option(name: .shortAndLong, help: "Language code (e.g. en, it, fr). Omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English instead of transcribing in source language.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | srt | vtt | json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout.")
    var output: String?

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Emit word-level timestamps in addition to segments. Slower; only visible in --format json.")
    var wordTimestamps: Bool = false

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("File not found: \(inputURL.path)")
        }

        let session = TranscriptionSession()
        let source = FileAudioSource(url: inputURL)

        let opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            wordTimestamps: wordTimestamps,
            verbose: verbose
        )

        // Download progress streamed to stderr so stdout stays clean for piping.
        let progress = ProgressReporter(label: "downloading \(model)")
        if verbose { stderr("Loading model \(model)…") }

        let transcript = try await session.transcribe(
            source: source,
            options: opts,
            downloadProgress: { p in progress.update(p) }
        )
        progress.finish()

        let rendered = try Exporters.exporter(for: format).render(transcript)

        if let output {
            let outURL = URL(fileURLWithPath: output)
            try rendered.write(to: outURL, atomically: true, encoding: .utf8)
            if verbose {
                stderr("Wrote \(transcript.segments.count) segments to \(outURL.path)")
            }
        } else {
            print(rendered)
        }
    }
}

extension ExportFormat: ExpressibleByArgument {}
