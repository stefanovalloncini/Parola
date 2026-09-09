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

    @Option(name: .shortAndLong, help: "Model variant (e.g. openai_whisper-large-v3_turbo). Defaults to the recommended model — Apple Speech on macOS 26, no download.")
    var model: String?

    @Option(name: .shortAndLong, help: "Language code (e.g. en, it, fr). Omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English instead of transcribing in source language.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | md | html | docx | pdf | csv | tsv | srt | vtt | json | jsonl | fcpxml | lrc.")
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

    @Flag(name: .long, help: "Skip a file the library already holds instead of transcribing it again.")
    var skipDuplicates: Bool = false

    @Option(name: .long, help: "Library folder to check for duplicates. Defaults to the app's library.")
    var library: String?

    func run() async throws {
        CLIDiagnostics.installIfWanted(alwaysOn: false)
        guard !inputs.isEmpty else {
            throw ValidationError("At least one input file is required.")
        }
        ParolaLog.info(.cli, "transcribe started", [.count: .int(inputs.count)])

        let resolved = try inputs.map(Self.resolveInput)
        if resolved.count > 1, resolved.contains(where: { $0.isURL }) {
            throw ValidationError("Batch mode doesn't support URLs. Pass URLs one at a time.")
        }

        var opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            wordTimestamps: wordTimestamps,
            verbose: verbose,
            initialPrompt: prompt,
            diarize: diarize,
            expectedSpeakers: speakers
        )
        opts.model = model ?? ModelCatalog.defaultModelID(for: opts)
        if let resolvedModel = opts.model, opts.language == nil {
            printEnglishOnlyAutoNotice(model: resolvedModel)
        }

        if resolved.count == 1 {
            try await transcribeSingle(input: resolved[0], options: opts)
        } else {
            let kept = await keepingNewFiles(resolved.map(\.url))
            guard !kept.isEmpty else { return }
            try await transcribeBatch(urls: kept, options: opts)
        }
    }

    private var libraryStore: LibraryStore {
        library.map { LibraryStore(libraryURL: URL(fileURLWithPath: $0, isDirectory: true), extraIndexer: nil) }
            ?? .shared
    }

    /// Prints the notice for every file the library already holds, and drops them when
    /// `--skip-duplicates` says to.
    private func keepingNewFiles(_ urls: [URL]) async -> [URL] {
        let store = libraryStore
        var kept: [URL] = []
        for url in urls {
            guard let existing = await DuplicateNotice.lookup(for: url, in: store).entry else {
                kept.append(url)
                continue
            }
            stderr(DuplicateNotice.text(for: existing, skipping: skipDuplicates))
            if !skipDuplicates { kept.append(url) }
        }
        return kept
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

        if case .file(let url) = input, await keepingNewFiles([url]).isEmpty { return }

        if case .youtube(let url) = input, preferExistingSubs {
            stderr("Fetching captions from \(url.absoluteString)…")
            emitter.progress(.downloading, detail: url.absoluteString)
            let transcript = orthographyCorrected(try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: language))
            try emitTranscript(transcript, sourceURL: url, emitter: emitter)
            return
        }

        let session = TranscriptionSession()
        let modelName = options.model ?? "model"
        let progress = ProgressReporter(label: "downloading \(modelName)")
        if verbose { stderr("Loading model \(modelName)…") }
        emitter.progress(.loading, detail: modelName)

        let source: any AudioSource
        let sourceURL: URL
        switch input {
        case .file(let url):
            source = FileAudioSource(url: url)
            sourceURL = url
        case .youtube(let url):
            try ParolaCLI.features.require(.youtube)
            stderr("Downloading audio from \(url.absoluteString)…")
            emitter.progress(.downloading, detail: url.absoluteString)
            let yt = try YouTubeAudioSource(url: url, features: ParolaCLI.features)
            source = yt
            sourceURL = try await yt.prepare()
        }

        emitter.progress(.transcribing, detail: sourceURL.lastPathComponent)
        var transcript = try await withStdoutRedirectedToStderr {
            try await session.transcribe(
                source: source,
                options: options,
                downloadProgress: { p in
                    progress.update(p)
                    emitter.progress(.downloading, fraction: p, detail: modelName)
                }
            )
        }
        progress.finish()
        transcript = orthographyCorrected(transcript)

        if summarise {
            do {
                transcript.summary = try await SummaryService().summarise(transcript)
            } catch {
                stderr("warning: summary skipped — \(error.localizedDescription)")
            }
        }
        warnIfLanguageAssumed(transcript)
        try emitTranscript(transcript, sourceURL: sourceURL, emitter: emitter)
    }

    private func warnIfLanguageAssumed(_ transcript: Transcript) {
        guard !mcp, let detection = transcript.languageDetection, detection.isAssumed else { return }
        stderr("note: couldn't detect the language — assumed \(detection.code). Re-run with --language to set it.")
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
                warnIfLanguageAssumed(transcript)
            case .failed(let id, let reason):
                if let job = jobByID[id] { stderr("✘ \(job.url.lastPathComponent): \(reason)") }
            case .cancelled(let id):
                if let job = jobByID[id] { stderr("⨯ \(job.url.lastPathComponent): cancelled") }
            case .progress:
                break
            case .finished:
                if verbose { stderr("Batch done (\(urls.count) files).") }
            }
        }
    }
}

extension ExportFormat: ExpressibleByArgument {}
