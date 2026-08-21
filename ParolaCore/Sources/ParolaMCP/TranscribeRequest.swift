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
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
