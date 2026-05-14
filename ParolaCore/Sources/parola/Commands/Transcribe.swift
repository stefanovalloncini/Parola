import ArgumentParser
import Foundation
import ParolaCore

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio or video file."
    )

    @Argument(help: "Path to one or more audio/video files. Multiple paths require --output-dir.")
    var inputs: [String]

    @Option(name: .shortAndLong, help: "Model variant (e.g. openai_whisper-tiny, openai_whisper-large-v3-turbo).")
    var model: String = "openai_whisper-tiny"

    @Option(name: .shortAndLong, help: "Language code (e.g. en, it, fr). Omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English instead of transcribing in source language.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | srt | vtt | json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout. Ignored when multiple inputs are given.")
    var output: String?

    @Option(name: .long, help: "Directory to write transcripts to when transcribing multiple files. Required for batch.")
    var outputDir: String?

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Emit word-level timestamps in addition to segments. Slower; only visible in --format json.")
    var wordTimestamps: Bool = false

    @Option(name: .long, help: "Initial prompt: short text that biases the decoder toward specific words (proper nouns, jargon).")
    var prompt: String?

    @Flag(name: .long, help: "Identify speakers and tag each segment (slower; loads a second model).")
    var diarize: Bool = false

    @Option(name: .long, help: "Hint for the diarizer: number of speakers in the audio. Omit to auto-detect.")
    var speakers: Int?

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one input file is required.")
        }

        let urls = try inputs.map { path -> URL in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("File not found: \(url.path)")
            }
            return url
        }

        let opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            wordTimestamps: wordTimestamps,
            verbose: verbose,
            initialPrompt: prompt,
            diarize: diarize,
            expectedSpeakers: speakers
        )

        if urls.count == 1 {
            try await transcribeSingle(url: urls[0], options: opts)
        } else {
            try await transcribeBatch(urls: urls, options: opts)
        }
    }

    private func transcribeSingle(url: URL, options: TranscriptionOptions) async throws {
        let session = TranscriptionSession()
        let progress = ProgressReporter(label: "downloading \(model)")
        if verbose { stderr("Loading model \(model)…") }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: url),
            options: options,
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

    private func transcribeBatch(urls: [URL], options: TranscriptionOptions) async throws {
        guard let outputDir else {
            throw ValidationError("Multiple inputs require --output-dir.")
        }
        let outDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

        let jobs = urls.map { BatchJob(url: $0) }
        let queue = BatchQueue()
        let events = await queue.process(jobs: jobs, options: options)

        let jobByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        for await event in events {
            switch event {
            case .started(let id):
                if let job = jobByID[id] { stderr("▶ \(job.url.lastPathComponent)") }
            case .completed(let id, let transcript):
                guard let job = jobByID[id] else { continue }
                let target = outDirURL.appendingPathComponent("\(job.displayName).\(format.fileExtension)")
                let rendered = try Exporters.exporter(for: format).render(transcript)
                try rendered.write(to: target, atomically: true, encoding: .utf8)
                stderr("✓ \(job.url.lastPathComponent) → \(target.path)")
            case .failed(let id, let reason):
                if let job = jobByID[id] { stderr("✘ \(job.url.lastPathComponent): \(reason)") }
            case .finished:
                if verbose { stderr("Batch done (\(urls.count) files).") }
            }
        }
    }
}

extension ExportFormat: ExpressibleByArgument {}
