import CoreTransferable
import Foundation
import ParolaCore
import UniformTypeIdentifiers

enum TranscriptShareFile {
    static func write(title: String, text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParolaShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: title))
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func fileName(for title: String) -> String {
        safeName(for: title) + ".txt"
    }

    /// A title carries the two characters the file system reads as separators, so every export name strips them.
    static func safeName(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Transcript" : cleaned
    }
}

/// A library row's transcript as a text file, read from its bundle only once a share target asks for it.
struct LibraryEntryShareFile: Transferable {
    let title: String
    let bundleURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let text = try ParolaDocument.readTranscriptText(at: file.bundleURL)
            return SentTransferredFile(
                try TranscriptShareFile.write(title: file.title, text: text), allowAccessingOriginalFile: false
            )
        }
    }
}
