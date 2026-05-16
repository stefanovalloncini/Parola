import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func applySpeakerRenames(_ renames: [String: String], on transcript: Transcript, entryID: LibraryEntry.ID) async -> Transcript {
        var updated = transcript
        let nonEmpty = renames.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        for (from, to) in nonEmpty {
            updated = updated.renamingSpeaker(from, to: to)
        }
        try? await library.updateTranscript(updated, for: entryID)
        for to in nonEmpty.values {
            _ = await peopleStore.recordUsage(name: to)
        }
        return updated
    }
}
