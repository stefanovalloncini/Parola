import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func applySpeakerRenames(_ renames: [String: String], on transcript: Transcript, entryID: LibraryEntry.ID) async -> Transcript {
        let nonEmpty = renames.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let updated = transcript.renamingSpeakers(nonEmpty)
        do {
            try await library.updateTranscript(updated, for: entryID)
        } catch {
            lastError = error.localizedDescription
        }
        for to in nonEmpty.values {
            _ = await peopleStore.recordUsage(name: to)
        }
        return updated
    }
}
