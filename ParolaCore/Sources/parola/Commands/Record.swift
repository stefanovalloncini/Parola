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

    @Option(name: .shortAndLong, help: "Seconds to record. Omit to record until Ctrl-C.")
    var seconds: Double?

    @Option(name: .shortAndLong, help: "Model variant.")
    var model: String = "openai_whisper-tiny"

    @Option(name: .shortAndLong, help: "Language code; omit to auto-detect.")
    var language: String?

    @Flag(help: "Translate to English.")
    var translate: Bool = false

    @Option(name: .shortAndLong, help: "Output format: txt | md | srt | vtt | json.")
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
        if stream {
            guard source == .mic else {
                throw ValidationError("--stream only works with --source mic")
            }
            try await runStreaming()
            return
        }

        try await runBatch()
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
        let opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose,
            initialPrompt: prompt
        )

        let progress = ProgressReporter(label: "downloading \(model)")
        let transcript = try await session.transcribe(
            source: audioSource,
            options: opts,
            downloadProgress: { p in progress.update(p) }
        )
        progress.finish()

        let rendered = try Exporters.exporter(for: format).render(transcript)
        if let output {
            try rendered.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        } else {
            print(rendered)
        }
    }

    private func runStreaming() async throws {
        let session = StreamingTranscriptionSession()
        let opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose,
            initialPrompt: prompt
        )

        stderr("Streaming from mic. Press Ctrl-C to stop." + (seconds.map { " (or wait \($0)s)" } ?? ""))

        let progress = ProgressReporter(label: "downloading \(model)")
        let events = try await session.start(
            options: opts,
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
                        let rendered = try Exporters.exporter(for: format).render(transcript)
                        if let output {
                            try rendered.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
                        } else {
                            print(rendered)
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
