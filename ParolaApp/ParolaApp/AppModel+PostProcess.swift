import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadIgnoredSegmentRules() {
        ignoredSegmentRules = readJSON([IgnoredSegmentRule].self, forKey: "ignoredSegmentRules") ?? SuggestedIgnoredPhrases.rules()
    }

    @discardableResult
    func addSuggestedIgnoredPhrases() -> Int {
        let missing = SuggestedIgnoredPhrases.missing(from: ignoredSegmentRules)
        ignoredSegmentRules.append(contentsOf: missing)
        return missing.count
    }

    func saveIgnoredSegmentRules() {
        writeJSON(ignoredSegmentRules, forKey: "ignoredSegmentRules")
    }

    func loadFindReplaceRules() {
        findReplaceRules = readJSON([FindReplaceRule].self, forKey: "findReplaceRules") ?? []
    }

    func saveFindReplaceRules() {
        writeJSON(findReplaceRules, forKey: "findReplaceRules")
    }

    var transcriptPostProcessor: TranscriptPostProcessor {
        TranscriptPostProcessor(ignoredRules: ignoredSegmentRules, findReplaceRules: findReplaceRules)
    }

    func postProcess(_ transcript: Transcript) -> Transcript {
        transcriptPostProcessor.apply(transcript)
    }

    /// Completion paths await this so a long regex pass can't hitch the UI as results land.
    func postProcessDetached(_ transcript: Transcript) async -> Transcript {
        if let postProcessOperation { return await postProcessOperation(transcript) }
        return await transcriptPostProcessor.applyOffActor(transcript)
    }

    /// The Speakers sheet's bulk rename. One simultaneous pass, so a pair like
    /// `["Speaker 1": "Speaker 2", "Speaker 2": "Anna"]` cannot collapse both speakers into Anna:
    /// every segment's new label is read from the label it carried before the pass.
    func applySpeakerRenames(_ renames: [String: String]) {
        var targets: [String: String] = [:]
        for (from, to) in renames where renamesSomething(from, to: to) {
            targets[from.trimmingCharacters(in: .whitespacesAndNewlines)] =
                to.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !targets.isEmpty, let current = transcript else { return }
        var edit = SpeakerAssignmentEdit()
        var reused: [Person] = []
        for (from, to) in targets {
            if let assigned = speakerAssignments[from] {
                edit.assign[to] = assigned
            } else if let existing = person(named: to) {
                edit.assign[to] = existing.id
                reused.append(existing)
            }
            edit.clear.append(from)
        }
        let renamed = current.renamingSpeakers(targets)
        guard renamed != current else { return }
        applyTranscriptEdit(
            renamed,
            actionName: String(localized: "Rename Speaker"),
            assignments: edit.isEmpty ? nil : edit
        )
        guard !reused.isEmpty else { return }
        Task { [peopleStore] in
            // The stored spelling, not the typed one: counting a use must not rename the person.
            for person in reused { _ = await peopleStore.recordUsage(name: person.name) }
            await refreshPeople()
        }
    }
}
