import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func recordChat(history: [ChatMessage], for entryID: LibraryEntry.ID?) {
        guard let entryID, entryID == selectedEntryID, var transcript = self.transcript else { return }
        transcript.chatHistory = history
        self.transcript = transcript
        Task { [library] in
            try? await library.setChatHistory(history, for: entryID)
        }
    }

    /// A recording owns the phase, and opening would set it to `.ready` under it.
    func summarizeLatestEntry(options: SummaryOptions? = nil) {
        introduction.defer()
        guard features.isEnabled(.ai), !phaseDefersArrivals else { return }
        Task { [weak self, library] in
            guard let self, let latest = await library.list().first, !self.phaseDefersArrivals else { return }
            do { try await self.openEntry(latest.id) } catch { return }
            self.summariseTranscript(options: options)
        }
    }

    /// The saved summary options with the given fields overridden, for a bridge caller that sends only what changed.
    func mergedSummaryOptions(overriding raw: [String: AutomationValue]) throws -> SummaryOptions {
        guard let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(summaryOptions)) as? [String: Any] else {
            throw AutomationError.invalidArgs(field: "options", reason: "could not encode the saved summary options")
        }
        var merged = base
        for (key, value) in raw {
            if case .null = value {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value.jsonObject
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(SummaryOptions.self, from: data) else {
            throw AutomationError.invalidArgs(field: "options", reason: "could not decode SummaryOptions from the given fields")
        }
        return decoded
    }
}
