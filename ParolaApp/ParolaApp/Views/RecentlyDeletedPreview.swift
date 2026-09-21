import Foundation
import ParolaCore

func readTranscriptText(at bundleURL: URL) async -> String {
    let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
    guard let data = try? Data(contentsOf: transcriptURL),
          let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
    else { return "" }
    return transcript.text
}

/// The pass that decodes what the per-row tasks have not: it hands each batch over as it is read, so a
/// search shows its matches while the rest of the trash is still being decoded.
@MainActor
enum RecentlyDeletedPreviews {
    static let batchSize = 25

    static func decode(
        _ entries: [LibraryEntry],
        batchSize: Int = batchSize,
        text: (LibraryEntry) async -> String,
        publish: ([LibraryEntry.ID: String]) -> Void
    ) async {
        var batch: [LibraryEntry.ID: String] = [:]
        for entry in entries {
            // break, not return: a cancelled pass keeps the bundles it already paid to read.
            if Task.isCancelled { break }
            batch[entry.id] = preview(of: await text(entry))
            if batch.count >= batchSize {
                publish(batch)
                batch = [:]
            }
        }
        if !batch.isEmpty { publish(batch) }
    }

    static func preview(of text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : String(trimmed.prefix(280))
    }
}
