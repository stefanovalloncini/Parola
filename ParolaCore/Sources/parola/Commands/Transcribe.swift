import ArgumentParser
import Foundation
import ParolaCore

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio or video file."
    )

    @Argument(help: "Path to one or more audio/video files, or a single YouTube URL. Multiple paths require --output-dir.")
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

    @Option(name: .long, help: "Also save a .parola bundle to this path (audio + transcript + manifest).")
    var save: String?

    @Flag(name: .long, help: "For YouTube URLs: prefer downloading existing captions over running Whisper.")
    var preferExistingSubs: Bool = false

    @Flag(name: .long, help: "Generate a summary and chapter markers via the on-device LLM (macOS 26+ / iOS 26+).")
    var summarise: Bool = false

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one input file is required.")
        }

        let resolved = try inputs.map(Self.resolveInput)
        if resolved.count > 1, resolved.contains(where: { $0.isURL }) {
            throw ValidationError("Batch mode doesn't support URLs. Pass URLs one at a time.")
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

        if resolved.count == 1 {
            try await transcribeSingle(input: resolved[0], options: opts)
        } else {
            try await transcribeBatch(urls: resolved.map(\.url), options: opts)
        }
    }

    private enum ResolvedInput {
        case file(URL)
        case youtube(URL)
        var url: URL { switch self { case .file(let u), .youtube(let u): return u } }
        var isURL: Bool { if case .youtube = self { return true } else { return false } }
    }

    private static func resolveInput(_ raw: String) throws -> ResolvedInput {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw), url.isYouTubeVideo else {
                throw ValidationError("Only YouTube URLs are supported. Got: \(raw)")
            }
            return .youtube(url)
        }
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(url.path)")
        }
        return .file(url)
    }

    private func transcribeSingle(input: ResolvedInput, options: TranscriptionOptions) async throws {
        if case .youtube(let url) = input, preferExistingSubs {
            stderr("Fetching captions from \(url.absoluteString)…")
            let transcript = try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: language)
            try emitTranscript(transcript, sourceURL: url)
            return
        }

        let session = TranscriptionSession()
        let progress = ProgressReporter(label: "downloading \(model)")
        if verbose { stderr("Loading model \(model)…") }

        let source: any AudioSource
        let sourceURL: URL
        switch input {
        case .file(let url):
            source = FileAudioSource(url: url)
            sourceURL = url
        case .youtube(let url):
            stderr("Downloading audio from \(url.absoluteString)…")
            let yt = YouTubeAudioSource(url: url)
            source = yt
            sourceURL = try await yt.prepare()
        }

        var transcript = try await session.transcribe(
            source: source,
            options: options,
            downloadProgress: { p in progress.update(p) }
        )
        progress.finish()

        if summarise {
            do {
                transcript.summary = try await SummaryService().summarise(transcript)
            } catch {
                stderr("warning: summary skipped — \(error.localizedDescription)")
            }
        }
        try emitTranscript(transcript, sourceURL: sourceURL)
    }

    private func emitTranscript(_ transcript: Transcript, sourceURL: URL) throws {
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
        if let savePath = save,
           FileManager.default.fileExists(atPath: sourceURL.path) {
            let bundle = try ParolaDocument.write(
                transcript: transcript,
                audioURL: sourceURL,
                to: URL(fileURLWithPath: savePath)
            )
            stderr("Saved bundle to \(bundle.path)")
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
