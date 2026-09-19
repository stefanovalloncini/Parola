#!/usr/bin/env swift
import AVFoundation
import Foundation

// Builds one demo clip for the first-run introduction. Run it through scripts/build-intro-clip.sh,
// which resolves the repo root and the CLI for it.

let levelRate = 20.0
let outputDirectory = URL(fileURLWithPath: "ParolaApp/ParolaApp/Resources/Introduction", isDirectory: true)
let cliPath = "ParolaCore/.build/debug/parola"
let preferredModels = ["openai_whisper-large-v3_turbo", "openai_whisper-tiny"]

struct Placeholder {
    let text: String
    let speaker: String
    let voice: String
}

let placeholders = [
    // Samantha reads "Parola" as "Parala"; the hyphen fixes her pronunciation and never reaches the transcript.
    "en": Placeholder(
        text: """
        This is Par-ola. It listens to a recording and writes down every word, right here on your Mac. \
        Nothing leaves this computer.
        """,
        speaker: "Speaker 1",
        voice: "Samantha"
    ),
    // The capitalisation step below capitalises every "parola" it finds, so a recording should avoid the common noun.
    "it": Placeholder(
        text: """
        Questa è Parola. Ascolta una registrazione e la scrive tutta, qui sul tuo Mac. \
        Niente esce da questo computer.
        """,
        speaker: "Voce 1",
        voice: "Alice"
    ),
]

struct CLIWord: Decodable {
    var word: String
    var start: Double
    var end: Double
}

struct CLISegment: Decodable {
    var words: [CLIWord]?
}

struct CLITranscript: Decodable {
    var segments: [CLISegment]
}

struct DemoWord: Encodable {
    var text: String
    var start: Double
    var end: Double
}

struct DemoScriptFile: Encodable {
    var text: String
    var speaker: String
    var duration: Double
    var levelRate: Double
    var levels: [Double]
    var words: [DemoWord]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        fail("could not run \(executable): \(error.localizedDescription)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("\(executable) exited with \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self)
}

func which(_ tool: String) -> String {
    for directory in ["/usr/bin", "/bin", "/usr/local/bin"] {
        let path = directory + "/" + tool
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    fail("could not find \(tool)")
}

func rounded(_ value: Double, places: Int) -> Double {
    let scale = pow(10.0, Double(places))
    return (value * scale).rounded() / scale
}

/// Whisper writes the app's name in lower case wherever it is also an ordinary word, so the
/// transcript gets one pass: a word whose letters spell "parola" becomes "Parola", punctuation kept.
func capitalisingAppName(_ text: String) -> String {
    let letters = text.trimmingCharacters(in: CharacterSet.letters.inverted)
    guard letters.lowercased() == "parola" else { return text }
    return text.replacingOccurrences(of: letters, with: "Parola")
}

func voiceExists(_ name: String) -> Bool {
    let listing = run(which("say"), ["-v", "?"])
    return listing.split(separator: "\n").contains { line in
        line.split(separator: " ", omittingEmptySubsequences: true).first == Substring(name)
    }
}

func installedModel() -> String {
    var installed: Set<String> = []
    for line in run(cliPath, ["models", "list"]).split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.first == "✓", fields.count > 1 else { continue }
        installed.insert(String(fields[1]))
    }
    guard let model = preferredModels.first(where: installed.contains) else {
        fail("no Whisper model installed — run: \(cliPath) models download openai_whisper-tiny")
    }
    return model
}

func timings(model: String, clip: URL, language: String) -> [DemoWord] {
    let printed = run(cliPath, [
        "transcribe", "--word-timestamps", "--format", "json",
        "--model", model, "--language", language, clip.path,
    ])
    guard let transcript = try? JSONDecoder().decode(CLITranscript.self, from: Data(printed.utf8)) else {
        fail("could not read the transcript the CLI printed")
    }
    return transcript.segments.flatMap { $0.words ?? [] }.map {
        DemoWord(
            text: $0.word.trimmingCharacters(in: .whitespacesAndNewlines),
            start: rounded($0.start, places: 3),
            end: rounded($0.end, places: 3)
        )
    }
}

/// RMS per 50 ms window over the mono mix, normalised so the loudest window reads full scale.
func measure(_ url: URL) -> (levels: [Double], duration: Double) {
    guard let file = try? AVAudioFile(forReading: url) else { fail("could not read \(url.path)") }
    let format = file.processingFormat
    guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        fail("\(url.lastPathComponent) holds no audio")
    }
    do {
        try file.read(into: buffer)
    } catch {
        fail("could not decode \(url.lastPathComponent): \(error.localizedDescription)")
    }
    guard let channels = buffer.floatChannelData else { fail("\(url.lastPathComponent) is not float audio") }

    let channelCount = Int(format.channelCount)
    let frameCount = Int(buffer.frameLength)
    let windowFrames = max(1, Int((format.sampleRate / levelRate).rounded()))
    var values: [Double] = []
    var start = 0
    while start < frameCount {
        let end = min(start + windowFrames, frameCount)
        var sum = 0.0
        for frame in start..<end {
            var mixed = 0.0
            for channel in 0..<channelCount { mixed += Double(channels[channel][frame]) }
            mixed /= Double(channelCount)
            sum += mixed * mixed
        }
        values.append((sum / Double(end - start)).squareRoot())
        start = end
    }

    let peak = values.max() ?? 0
    let scale = peak > 0 ? 1 / peak : 1
    let levels = values.map { rounded(min(1, max(0, $0 * scale)), places: 3) }
    return (levels, Double(file.length) / format.sampleRate)
}

var positional: [String] = []
var voiceOverride: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--voice":
        guard let name = arguments.first else { fail("--voice needs a voice name") }
        voiceOverride = name
        arguments.removeFirst()
    case "-h", "--help":
        print("Usage: scripts/build-intro-clip.sh <en|it> [recording] [--voice NAME]")
        exit(0)
    default:
        positional.append(argument)
    }
}

guard let language = positional.first, let placeholder = placeholders[language] else {
    fail("first argument must be en or it")
}

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let clipURL = outputDirectory.appendingPathComponent("demo-\(language).m4a")
let scriptURL = outputDirectory.appendingPathComponent("demo-\(language).json")
let spokenURL = FileManager.default.temporaryDirectory.appendingPathComponent("parola-intro-\(language).aiff")

let sourceURL: URL
if positional.count > 1 {
    sourceURL = URL(fileURLWithPath: positional[1])
    guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { fail("cannot read \(sourceURL.path)") }
    print("speaking: \(sourceURL.lastPathComponent)")
} else {
    let requested = voiceOverride ?? placeholder.voice
    let voice = voiceExists(requested) ? [requested] : []
    if voice.isEmpty { print("voice \(requested) is not installed — using the system default") }
    run(which("say"), voice.flatMap { ["-v", $0] } + ["-r", "170", "-o", spokenURL.path, placeholder.text])
    sourceURL = spokenURL
    print("spoke the \(language) placeholder with \(voice.first ?? "the default voice")")
}

try? FileManager.default.removeItem(at: clipURL)
// AAC refuses `say`'s 22.05 kHz output without an explicit rate ('!dat').
run(which("afconvert"), ["-f", "m4af", "-d", "aac@44100", "-b", "96000", sourceURL.path, clipURL.path])
try? FileManager.default.removeItem(at: spokenURL)

let measured = measure(clipURL)
let model = installedModel()
print("transcribing with \(model)…")
var words = timings(model: model, clip: clipURL, language: language)
guard !words.isEmpty else { fail("the transcript has no word timings") }
words = words.map { DemoWord(text: capitalisingAppName($0.text), start: $0.start, end: $0.end) }

let script = DemoScriptFile(
    text: words.map(\.text).joined(separator: " "),
    speaker: placeholder.speaker,
    duration: rounded(measured.duration, places: 3),
    levelRate: levelRate,
    levels: measured.levels,
    words: words
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
guard let data = try? encoder.encode(script) else { fail("could not encode the script") }
do {
    try data.write(to: scriptURL)
} catch {
    fail("could not write \(scriptURL.path): \(error.localizedDescription)")
}

for word in words {
    print(String(format: "%7.2f %7.2f  %@", word.start, word.end, word.text))
}
let ordered = script.levels.sorted()
print("""
\nwrote \(clipURL.path) (\(String(format: "%.2f", script.duration)) s)
wrote \(scriptURL.path) with \(model) (\(words.count) words, \(script.levels.count) levels; \
min \(ordered.first ?? 0), median \(ordered[ordered.count / 2]), max \(ordered.last ?? 0))
""")
