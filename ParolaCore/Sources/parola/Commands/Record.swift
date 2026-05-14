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

    @Option(name: .shortAndLong, help: "Output format: txt | srt | vtt | json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout.")
    var output: String?

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose: Bool = false

    func run() async throws {
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

        let stopSignal = AsyncSignalStream(signal: SIGINT)
        let timer: Task<Void, Never>? = seconds.map { secs in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                stopSignal.fire()
            }
        }
        await stopSignal.wait()
        timer?.cancel()

        let session = TranscriptionSession()
        let opts = TranscriptionOptions(
            model: model,
            language: language,
            task: translate ? .translate : .transcribe,
            verbose: verbose
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
}
