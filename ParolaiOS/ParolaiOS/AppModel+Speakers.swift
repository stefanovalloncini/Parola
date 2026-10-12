import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func applySpeakerRenames(_ renames: [String: String], on transcript: Transcript, entryID: LibraryEntry.ID) async -> Transcript {
        let nonEmpty = renames.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var spelled: [String: String] = [:]
        for (from, to) in nonEmpty {
            spelled[from] = await peopleStore.recordUsage(name: to).name
        }
        let updated = transcript.renamingSpeakers(spelled)
        do {
            try await library.updateTranscript(updated, for: entryID)
        } catch {
            lastError = error.localizedDescription
        }
        return updated
    }
}
