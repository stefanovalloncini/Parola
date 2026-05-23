import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadIgnoredSegmentRules() {
        if let rules = readJSON([IgnoredSegmentRule].self, forKey: "ignoredSegmentRules") {
            ignoredSegmentRules = rules
        }
    }

    func saveIgnoredSegmentRules() {
        writeJSON(ignoredSegmentRules, forKey: "ignoredSegmentRules")
    }

    func loadFindReplaceRules() {
        if let rules = readJSON([FindReplaceRule].self, forKey: "findReplaceRules") {
            findReplaceRules = rules
        }
    }

    func saveFindReplaceRules() {
        writeJSON(findReplaceRules, forKey: "findReplaceRules")
    }

    func postProcess(_ transcript: Transcript) -> Transcript {
        var out = transcript
        out.segments = IgnoredSegments.apply(rules: ignoredSegmentRules, to: out.segments)
        out.segments = GlobalFindReplace.apply(rules: findReplaceRules, to: out.segments)
        return out
    }

    func applySpeakerRenames(_ renames: [String: String]) {
        guard var transcript = self.transcript else { return }
        let nonEmpty = renames.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        for (from, to) in nonEmpty {
            transcript = transcript.renamingSpeaker(from, to: to)
        }
        self.transcript = transcript
        if let id = selectedEntryID {
            Task { [library] in try? await library.updateTranscript(transcript, for: id) }
        }
        Task { [peopleStore] in
            for to in nonEmpty.values {
                _ = await peopleStore.recordUsage(name: to)
            }
        }
    }
}
