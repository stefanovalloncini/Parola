import ArgumentParser
import Foundation
import ParolaCore

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark installed models on a corpus and print a markdown table."
    )

    @Option(help: "Directory containing .wav files to benchmark on. Default: synthesizes a short clip.")
    var corpus: String?

    @Option(help: "Comma-separated list of model variants to test. Default: every installed catalog entry.")
    var models: String?

    @Option(help: "Language hint (skipped for English-only engines).")
    var language: String?

    @Option(help: "Where to write a JSON snapshot. Default: ~/Library/Application Support/Parola/benchmarks/<ts>.json")
    var snapshot: String?

    func run() async throws {
        let modelIDs = try resolveModels()
        let audioFiles = try await prepareCorpus()
        guard !audioFiles.isEmpty else {
            stderr("No audio files in corpus.")
            throw ExitCode.failure
        }

        var rows: [BenchRow] = []
        for modelID in modelIDs {
            let row = try await bench(modelID: modelID, audioFiles: audioFiles, language: language)
            rows.append(row)
            printRow(row)
        }

        printTable(rows: rows)

        try writeSnapshot(rows: rows, to: snapshot)
    }

    private func resolveModels() throws -> [String] {
        if let models {
            return models.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let store = ModelStore.shared
        let installed = store.catalog().filter { $0.isInstalled }.map { $0.name }
        guard !installed.isEmpty else {
            stderr("No installed models. Run `parola models download <id>` first, or pass --models <id>.")
            throw ExitCode.failure
        }
        return installed
    }

    private func prepareCorpus() async throws -> [URL] {
        if let corpus {
            let url = URL(fileURLWithPath: corpus)
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { ["wav", "mp3", "m4a", "aiff"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
        }
        return [try await synthesizeClip()]
    }

    private func synthesizeClip() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parola-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appendingPathComponent("clip.aiff")
        let wav = dir.appendingPathComponent("clip.wav")
        let phrase = "Parola transcribes audio on your Mac using on device models. This is a short benchmark clip."
        try runShell("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, phrase])
        try runShell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return wav
    }

    private func bench(modelID: String, audioFiles: [URL], language: String?) async throws -> BenchRow {
        let session = TranscriptionSession()
        let variant = ModelCatalog.variant(id: modelID)
        let effectiveLanguage: String? = {
            if case .some(.only(let codes)) = variant?.languageScope, codes == ["en"] {
                return "en"
            }
            return language
        }()

        var totalAudioSeconds: Double = 0
        var totalWallSeconds: Double = 0
        var totalWords = 0
        let startRSS = currentResidentBytes()
        var peakRSS = startRSS

        for file in audioFiles {
            let source = FileAudioSource(url: file)
            let started = Date()
            let transcript = try await session.transcribe(
                source: source,
                options: TranscriptionOptions(model: modelID, language: effectiveLanguage)
            )
            let elapsed = Date().timeIntervalSince(started)
            totalWallSeconds += elapsed
            totalAudioSeconds += transcript.durationSeconds ?? estimateDuration(file)
            totalWords += transcript.text.split(whereSeparator: { $0.isWhitespace }).count
            peakRSS = max(peakRSS, currentResidentBytes())
        }
        await session.unloadModel()

        let endRSS = currentResidentBytes()
        return BenchRow(
            model: modelID,
            displayName: variant?.displayName ?? modelID,
            audioSeconds: totalAudioSeconds,
            wallSeconds: totalWallSeconds,
            wordsTranscribed: totalWords,
            peakRSSBytes: peakRSS,
            deltaRSSBytes: Int64(endRSS) - Int64(startRSS)
        )
    }

    private func printRow(_ row: BenchRow) {
        stderr(String(format: "  %@ → wall %.2fs, RTF %.1fx, %d words, peak RSS %@",
                      row.model,
                      row.wallSeconds,
                      row.realTimeFactor,
                      row.wordsTranscribed,
                      humanBytes(Int(row.peakRSSBytes))))
    }

    private func printTable(rows: [BenchRow]) {
        print("")
        print("| Model | Audio | Wall | RTF | Words | Peak RSS | ΔRSS |")
        print("|---|---:|---:|---:|---:|---:|---:|")
        for row in rows {
            print("| \(row.displayName) | \(format(row.audioSeconds))s | \(format(row.wallSeconds))s | \(String(format: "%.1fx", row.realTimeFactor)) | \(row.wordsTranscribed) | \(humanBytes(Int(row.peakRSSBytes))) | \(deltaString(row.deltaRSSBytes)) |")
        }
    }

    private func writeSnapshot(rows: [BenchRow], to override: String?) throws {
        let url: URL
        if let override {
            url = URL(fileURLWithPath: override)
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Parola", isDirectory: true)
                .appendingPathComponent("benchmarks", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            url = dir.appendingPathComponent("\(stamp).json")
        }
        let data = try JSONEncoder.pretty.encode(rows)
        try data.write(to: url)
        stderr("Wrote snapshot to \(url.path)")
    }

    private func format(_ s: Double) -> String { String(format: "%.2f", s) }

    private func deltaString(_ bytes: Int64) -> String {
        let abs = humanBytes(Int(Swift.abs(bytes)))
        return bytes >= 0 ? "+\(abs)" : "-\(abs)"
    }

    private func estimateDuration(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return Double(size) / 32_000.0
    }
}

struct BenchRow: Codable {
    let model: String
    let displayName: String
    let audioSeconds: Double
    let wallSeconds: Double
    let wordsTranscribed: Int
    let peakRSSBytes: UInt64
    let deltaRSSBytes: Int64

    var realTimeFactor: Double {
        guard wallSeconds > 0 else { return 0 }
        return audioSeconds / wallSeconds
    }
}

private func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func runShell(_ launchPath: String, _ arguments: [String]) throws {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw ParolaError.ioError("\(launchPath) exited \(task.terminationStatus)")
    }
}
