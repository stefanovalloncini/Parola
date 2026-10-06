import Foundation
import ParolaCore

/// The AI results a transcript carries, kept so that clearing or replacing them can be undone.
struct AIResultsSnapshot: Sendable {
    enum Field: Sendable {
        case summary, chapters, actionItems
    }

    let summary: Summary?
    let chapters: [Chapter]?
    let actionItems: [ActionItem]?

    init(_ transcript: Transcript) {
        summary = transcript.summary
        chapters = transcript.chapters ?? transcript.summary?.chapters
        actionItems = transcript.actionItems
    }
}

extension AppModel {
    var aiResultsSnapshot: AIResultsSnapshot? {
        transcript.map(AIResultsSnapshot.init)
    }

    /// Registers the undo for a clear or a replacing run: it puts `fields` back as `before` held them, and redo swaps again.
    func registerAIResultsUndo(_ actionName: String, fields: Set<AIResultsSnapshot.Field>, before: AIResultsSnapshot) {
        let entryID = selectedEntryID
        let artifacts = derivedArtifactsGeneration
        registerUndoStep(actionName: actionName) { model in
            guard model.isOnScreen(entryID, askedAt: artifacts), let after = model.aiResultsSnapshot else { return }
            model.restoreAIResults(before, fields: fields)
            model.registerAIResultsUndo(actionName, fields: fields, before: after)
        }
    }

    private func restoreAIResults(_ snapshot: AIResultsSnapshot, fields: Set<AIResultsSnapshot.Field>) {
        guard var restored = transcript else { return }
        if fields.contains(.summary) { restored.summary = snapshot.summary }
        if fields.contains(.chapters) { restored.chapters = snapshot.chapters }
        if fields.contains(.actionItems) { restored.actionItems = snapshot.actionItems }
        if let chapters = restored.chapters { restored.summary?.chapters = chapters }
        transcript = restored
        actionItems = restored.actionItems ?? []
        adoptSavedChapters()
        guard let entryID = selectedEntryID else { return }
        let saved = restored
        Task { [library] in
            do {
                try await library.mutateTranscript(for: entryID) { stored in
                    if fields.contains(.summary) { stored.summary = saved.summary }
                    if fields.contains(.chapters) { stored.chapters = saved.chapters }
                    if fields.contains(.actionItems) { stored.actionItems = saved.actionItems }
                    if let chapters = stored.chapters { stored.summary?.chapters = chapters }
                }
            } catch {
                ParolaLog.error(.library, "restored AI results could not be saved to the library", [.error: .error(error)])
            }
        }
    }
}
