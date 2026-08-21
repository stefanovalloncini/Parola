import Foundation
import ParolaCore

enum TranscribeFormat: String, CaseIterable, Sendable {
    case txt
    case md
    case srt
    case vtt
    case json

    func render(_ transcript: Transcript) throws -> String {
        switch self {
        case .txt:  return transcript.text
        case .md:   return try MarkdownExporter().renderText(transcript)
        case .srt:  return try SrtExporter().renderText(transcript)
        case .vtt:  return try VttExporter().renderText(transcript)
        case .json: return try JsonExporter().renderText(transcript)
        }
    }
}

/// The arguments of one `parola_transcribe` call, parsed and validated before any audio is touched.
struct TranscribeRequest: Sendable {
    let sourceURL: URL
    let options: TranscriptionOptions
    let format: TranscribeFormat
    let outputURL: URL?
    let save: Bool

    init(args: [String: Any]) throws {
        guard let path = Self.text(args["path"]) else {
            throw MCPToolError("Missing required argument: path")
        }
        let name = (Self.text(args["format"]) ?? TranscribeFormat.txt.rawValue).lowercased()
        guard let format = TranscribeFormat(rawValue: name) else {
            let known = TranscribeFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPToolError("Unknown format \"\(name)\". Use one of: \(known).")
        }
        sourceURL = URL(fileURLWithPath: path)
        self.format = format
        options = TranscriptionOptions(
            model: Self.text(args["model"]),
            language: Self.text(args["language"]),
            task: args["translate"] as? Bool == true ? .translate : .transcribe,
            initialPrompt: Self.text(args["initial_prompt"])
        )
        outputURL = try Self.outputURL(args["output_path"])
        save = args["save"] as? Bool ?? false
    }

    /// Writes the rendered transcript where the call asked for it, creating missing parents, and
    /// returns that file. Nil when the call carried no `output_path`.
    func writeOutput(_ rendered: String) throws -> URL? {
        guard let outputURL else { return nil }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(rendered.utf8).write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func outputURL(_ value: Any?) throws -> URL? {
        guard let path = text(value) else { return nil }
        // Resolving a relative path against the server's working directory would drop the file
        // somewhere neither the client nor the user can predict.
        guard path.hasPrefix("/") else {
            throw MCPToolError("output_path must be an absolute path, got \"\(path)\".")
        }
        let url = URL(fileURLWithPath: path)
        try requireWritable(url)
        return url
    }

    /// Probed before the run starts: an hour of transcription must not end on an unwritable path.
    private static func requireWritable(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw MCPToolError("output_path \"\(url.path)\" is a directory, not a file.")
            }
            guard fm.isWritableFile(atPath: url.path) else {
                throw MCPToolError("output_path \"\(url.path)\" is not writable.")
            }
            return
        }
        var ancestor = url.deletingLastPathComponent()
        while !fm.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { break }
            ancestor = parent
        }
        guard isDirectory.boolValue, fm.isWritableFile(atPath: ancestor.path) else {
            throw MCPToolError("output_path \"\(url.path)\" is not writable: \(ancestor.path) is not a folder this can write into.")
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Stands in for a transcript that went to a file: what landed where, plus enough of the head to
/// see it worked. Keeps a long recording out of the client's context.
enum TranscribeReport {
    static let previewCharacters = 500
    static let noSpeechNote = "No speech detected: the transcript is empty."

    static func text(
        for transcript: Transcript,
        rendered: String,
        format: TranscribeFormat,
        outputURL: URL
    ) -> String {
        let count = transcript.segments.count
        let duration = transcript.durationSeconds ?? transcript.segments.last?.end ?? 0
        let body = rendered.isEmpty ? noSpeechNote : "Preview:\n\(preview(of: rendered))"
        return """
        Wrote \(format.rawValue) to \(outputURL.path)
        \(count) segment\(count == 1 ? "" : "s"), \(Format.timestampHHMMSS(duration))

        \(body)
        """
    }

    static func preview(of rendered: String) -> String {
        let head = rendered.prefix(previewCharacters)
        return head.count < rendered.count ? head + "…" : String(head)
    }
}
