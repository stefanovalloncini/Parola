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

    @Option(name: .shortAndLong, help: "Model variant (e.g. openai_whisper-tiny, openai_whisper-large-v3_turbo).")
    var model: String = "openai_whisper-tiny"

    @Option(name: .shortAndLong, help: "Language code (e.g. en, it, fr). Omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English instead of transcribing in source language.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | md | html | docx | pdf | csv | tsv | srt | vtt | json | jsonl | fcpxml.")
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

    @Flag(name: .long, help: "Emit NDJSON progress on stderr and one MCP-shaped JSON content block on stdout.")
    var mcp: Bool = false

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
        let emitter = MCPProgressEmitter(enabled: mcp)

        if case .youtube(let url) = input, preferExistingSubs {
            stderr("Fetching captions from \(url.absoluteString)…")
            emitter.progress(.downloading, detail: url.absoluteString)
            let transcript = orthographyCorrected(try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: language))
            try emitTranscript(transcript, sourceURL: url, emitter: emitter)
            return
        }

        let session = TranscriptionSession()
        let progress = ProgressReporter(label: "downloading \(model)")
        if verbose { stderr("Loading model \(model)…") }
        emitter.progress(.loading, detail: model)

        let source: any AudioSource
        let sourceURL: URL
        switch input {
        case .file(let url):
            source = FileAudioSource(url: url)
            sourceURL = url
        case .youtube(let url):
            stderr("Downloading audio from \(url.absoluteString)…")
            emitter.progress(.downloading, detail: url.absoluteString)
            let yt = try YouTubeAudioSource(url: url)
            source = yt
            sourceURL = try await yt.prepare()
        }

        emitter.progress(.transcribing, detail: sourceURL.lastPathComponent)
        var transcript = try await session.transcribe(
            source: source,
            options: options,
            downloadProgress: { p in
                progress.update(p)
                emitter.progress(.downloading, fraction: p, detail: model)
            }
        )
        progress.finish()
        transcript = orthographyCorrected(transcript)

        if summarise {
            do {
                transcript.summary = try await SummaryService().summarise(transcript)
            } catch {
                stderr("warning: summary skipped — \(error.localizedDescription)")
            }
        }
        try emitTranscript(transcript, sourceURL: sourceURL, emitter: emitter)
    }

    private func emitTranscript(_ transcript: Transcript, sourceURL: URL, emitter: MCPProgressEmitter) throws {
        let exporter = Exporters.exporter(for: format)
        emitter.progress(.exporting, detail: format.rawValue)

        if mcp {
            let rendered = try exporter.renderText(transcript)
            emitter.result(text: rendered)
        } else if let output {
            let outURL = URL(fileURLWithPath: output)
            let data = try exporter.render(transcript)
            try data.write(to: outURL, options: .atomic)
            if verbose {
                stderr("Wrote \(transcript.segments.count) segments to \(outURL.path)")
            }
        } else {
            print(try exporter.renderText(transcript))
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
        emitter.progress(.finished, fraction: 1.0)
    }

    private func orthographyCorrected(_ transcript: Transcript) -> Transcript {
        var out = transcript
        out.segments = ItalianOrthography.apply(to: out.segments, language: out.language)
        return out
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
                let rendered = try Exporters.exporter(for: format).render(orthographyCorrected(transcript))
                try rendered.write(to: target, options: .atomic)
                stderr("✓ \(job.url.lastPathComponent) → \(target.path)")
            case .failed(let id, let reason):
                if let job = jobByID[id] { stderr("✘ \(job.url.lastPathComponent): \(reason)") }
            case .cancelled(let id):
                if let job = jobByID[id] { stderr("⨯ \(job.url.lastPathComponent): cancelled") }
            case .finished:
                if verbose { stderr("Batch done (\(urls.count) files).") }
            }
        }
    }
}

extension ExportFormat: ExpressibleByArgument {}
