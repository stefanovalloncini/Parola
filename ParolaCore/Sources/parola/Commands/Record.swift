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

        let progress = ProgressReporter(label: "downloading \(opts.model ?? "model")")
        let transcript = try await withStdoutRedirectedToStderr {
            try await session.transcribe(
                source: audioSource,
                options: opts,
                downloadProgress: { p in progress.update(p) }
            )
        }
        progress.finish()

        let exporter = Exporters.exporter(for: format)
        if let output {
            try exporter.render(transcript).write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            print(try exporter.renderText(transcript))
        }
    }

    private func runStreaming() async throws {
        let session = StreamingTranscriberFactory.make()
        let streamModel = model ?? ModelCatalog.fallbackModelID
        let opts = TranscriptionOptions(
            model: streamModel,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose,
            initialPrompt: prompt
        )

        stderr("Streaming from mic. Press Ctrl-C to stop." + (seconds.map { " (or wait \($0)s)" } ?? ""))

        let progress = ProgressReporter(label: "downloading \(streamModel)")
        let events = try await session.start(
            options: opts,
            speakerLabeler: nil,
            downloadProgress: { p in progress.update(p) }
        )
        progress.finish()

        let consumer = Task {
            for await event in events {
                switch event {
                case .partial(let text):
                    FileHandle.standardError.write(Data("\r\u{001B}[2K… \(text)".utf8))
                case .confirmed(let segment):
                    FileHandle.standardError.write(Data("\r\u{001B}[2K".utf8))
                    print(segment.text.trimmingCharacters(in: .whitespaces))
                case .voiceActivity:
                    break
                case .warning(let msg):
                    stderr("\nwarning: \(msg)")
                case .failed(let msg):
                    stderr("\nerror: \(msg)")
                case .finished(let transcript):
                    let owesFinalRender = format != .txt || output != nil
                    guard owesFinalRender else { break }
                    do {
                        let exporter = Exporters.exporter(for: format)
                        if let output {
                            try exporter.render(transcript).write(to: URL(fileURLWithPath: output), options: .atomic)
                        } else {
                            print(try exporter.renderText(transcript))
                        }
                    } catch {
                        stderr("error: failed to write output — \(error.localizedDescription)")
                    }
                }
            }
        }

        await awaitStop(seconds: seconds)
        await session.stop()
        await consumer.value
    }
}
