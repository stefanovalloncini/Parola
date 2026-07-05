import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct TranscriptShareFile: Transferable {
    let title: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            SentTransferredFile(try write(title: file.title, text: file.text), allowAccessingOriginalFile: false)
        }
    }

    static func write(title: String, text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParolaShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: title))
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func fileName(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Transcript" : cleaned) + ".txt"
    }
}
