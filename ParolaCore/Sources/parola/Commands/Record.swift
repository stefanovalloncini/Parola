import ArgumentParser
import Foundation
import ParolaCore

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record from microphone or system audio, then transcribe."
    )

    enum Source: String, ExpressibleByArgument, CaseIterable {
        case mic
        case system
    }

    @Option(name: .shortAndLong, help: "Audio source: mic | system.")
    var source: Source = .mic

    @Option(name: [.customShort("d"), .long], help: "Duration in seconds. Omit to record until Ctrl-C.")
    var seconds: Double?

    @Option(name: .shortAndLong, help: "Model variant. Defaults to the recommended model; --stream uses \(ModelCatalog.fallbackModelID).")
    var model: String?

    @Option(name: .shortAndLong, help: "Language code; omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | md | html | docx | pdf | csv | tsv | srt | vtt | json | jsonl | fcpxml | lrc.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout.")
    var output: String?

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Stream partial transcription to stderr as you speak (mic only).")
    var stream: Bool = false

    @Option(name: .long, help: "Initial prompt: short text that biases the decoder toward specific words.")
    var prompt: String?

    func run() async throws {
        CLIDiagnostics.installIfWanted(alwaysOn: true)
        switch source {
        case .mic: try ParolaCLI.features.require(.micRecording)
        case .system: try ParolaCLI.features.require(.meetings)
        }
        ParolaLog.info(
            .cli, "record started from \(source)",
            model.map { [LogField.model: LogValue.safe(ModelToken($0))] } ?? [:]
        )
        if stream {
            guard source == .mic else {
                throw ValidationError("--stream only works with --source mic")
            }
            try await runStreaming()
        } else {
            try await runBatch()
        }
        await CLIDiagnostics.flush()
    }

    private func runBatch() async throws {
        let audioSource: any AudioSource
        switch source {
        case .mic:
            let mic = MicAudioSource()
            try await mic.start()
            audioSource = mic
        case .system:
            let sys = SystemAudioSource()
            try await sys.start()
            audioSource = sys
        }

        stderr("Recording from \(source.rawValue). Press Ctrl-C to stop." + (seconds.map { " (or wait \($0)s)" } ?? ""))
        await awaitStop(seconds: seconds)

        let session = TranscriptionSession()
        var opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose,
            initialPrompt: prompt
        )
        opts.model = model ?? ModelCatalog.defaultModelID(for: opts)
        if let resolvedModel = opts.model, opts.language == nil {
            printEnglishOnlyAutoNotice(model: resolvedModel)
        }

        let progress = ProgressReporter(label: "downloading \(opts.model ?? "model")")
        let transcript = try await withStdoutRedirectedToStderr {
            try await session.transcribe(
                source: audioSource,
                options: opts,
                downloadProgress: { p in progress.update(p) }
            )
        }
        progress.finish()
        try emit(transcript)
    }

    /// Both paths end here, so a batch take and a streamed one read the same.
    func emit(_ transcript: Transcript, to sink: RecordSink = .standard) throws {
        let finished = TranscriptPostProcessor.orthographyOnly.apply(transcript)
        let exporter = Exporters.exporter(for: format)
        if let output {
            try exporter.render(finished).write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            sink.out(try exporter.renderText(finished))
        }
    }

    /// A txt take to stdout is the live lines themselves, so each one is tidied as it prints.
    func handle(_ event: StreamingEvent, lines: inout LiveLineTidier, sink: RecordSink) {
        switch event {
        case .partial(let text):
            sink.err("\r\u{001B}[2K… \(text)")
        case .confirmed(let segment):
            sink.err("\r\u{001B}[2K")
            if let line = lines.tidy(segment) { sink.out(line.text) }
        case .voiceActivity:
            break
        case .warning(let msg):
            sink.err("\nwarning: \(msg)\n")
        case .failed(let msg):
            sink.err("\nerror: \(msg)\n")
        case .finished(let transcript):
            guard format != .txt || output != nil else { break }
            do {
                try emit(transcript, to: sink)
            } catch {
                sink.err("error: failed to write output — \(error.localizedDescription)\n")
            }
        }
    }

    private func runStreaming() async throws {
        let session = StreamingTranscriberFactory.make(waitsForModelOnStop: true)
        let streamModel = model ?? ModelCatalog.fallbackModelID
        let opts = TranscriptionOptions(
            model: streamModel,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose,
            initialPrompt: prompt
        )

        stderr("Streaming from mic. Press Ctrl-C to stop." + (seconds.map { " (or wait \($0)s)" } ?? ""))

        // The mic is up while the model loads, so Ctrl-C or --seconds can stop the take before start returns; it then waits for the model.
        let (stopRequests, requestStop) = AsyncStream<Void>.makeStream()
        let interrupts = StopThenInterrupt {
            stderr("\nStopping. Press Ctrl-C again to quit now.")
            requestStop.yield()
        }
        let stopping = Task {
            for await _ in stopRequests { break }
            await session.stop()
        }
        let meter = session.levelMeter
        var timers: [Task<Void, Never>] = []
        if let seconds {
            timers.append(Self.stopTimer(requestStop) { await meter.waitForAudio(seconds: seconds) })
        }
        defer {
            for timer in timers { timer.cancel() }
            interrupts.end()
        }

        let progress = ProgressReporter(label: "downloading \(streamModel)")
        let events: AsyncStream<StreamingEvent>
        do {
            events = try await session.start(
                options: opts,
                speakerLabeler: nil,
                downloadProgress: { p in progress.update(p) }
            )
        } catch {
            requestStop.finish()
            await stopping.value
            throw error
        }
        progress.finish()

        let endedByInterrupt = await play(events, interrupted: { interrupts.wasInterrupted }, sink: .standard)
        requestStop.finish()
        await stopping.value
        if endedByInterrupt { throw ExitCode(130) }
    }

    private static func stopTimer(
        _ requestStop: AsyncStream<Void>.Continuation, after wait: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            await wait()
            if !Task.isCancelled { requestStop.yield() }
        }
    }

    /// Prints the take as its events come. A take an interrupt left without words writes nothing and returns true, so the run ends as interrupted.
    func play(_ events: AsyncStream<StreamingEvent>, interrupted: () -> Bool, sink: RecordSink) async -> Bool {
        var lines = LiveLineTidier(language: language)
        var endedByInterrupt = false
        for await event in events {
            if case .finished(let transcript) = event, transcript.segments.isEmpty, interrupted() {
                endedByInterrupt = true
                continue
            }
            handle(event, lines: &lines, sink: sink)
        }
        return endedByInterrupt
    }
}

/// Where `parola record` writes: stdout carries the transcript, stderr everything else.
struct RecordSink: Sendable {
    var out: @Sendable (String) -> Void
    var err: @Sendable (String) -> Void

    static let standard = RecordSink(
        out: { print($0) },
        err: { FileHandle.standardError.write(Data($0.utf8)) }
    )
}

extension Record.Source: LogSafe {
    var logToken: String { rawValue }
}
