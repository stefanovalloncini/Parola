import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func recordChat(history: [ChatMessage]) {
        guard var transcript = self.transcript else { return }
        transcript.chatHistory = history
        self.transcript = transcript
        guard let id = selectedEntryID else { return }
        Task { [library] in
            try? await library.updateTranscript(transcript, for: id)
        }
    }

    func summarizeLatestEntry() {
        Task { [weak self, library] in
            guard let self else { return }
            let entries = await library.list()
            guard let latest = entries.first else { return }
            do {
                let loaded = try await library.load(latest.id)
                self.transcript = loaded.document.transcript
                self.selectedEntryID = latest.id
                self.summariseTranscript()
            } catch { }
        }
    }
}
