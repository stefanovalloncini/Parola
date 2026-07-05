import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadIgnoredSegmentRules() {
        ignoredSegmentRules = readJSON([IgnoredSegmentRule].self, forKey: "ignoredSegmentRules") ?? []
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

    func postProcess(_ transcript: Transcript) -> Transcript {
        Self.postProcess(transcript, ignoredRules: ignoredSegmentRules, findReplaceRules: findReplaceRules)
    }

    nonisolated static func postProcess(
        _ transcript: Transcript,
        ignoredRules: [IgnoredSegmentRule],
        findReplaceRules: [FindReplaceRule]
    ) -> Transcript {
        var out = transcript
        out.segments = IgnoredSegments.apply(rules: ignoredRules, to: out.segments)
        out.segments = GlobalFindReplace.apply(rules: findReplaceRules, to: out.segments)
        out.segments = ItalianOrthography.apply(to: out.segments, language: out.language)
        return out
    }

    /// Runs the rule pipeline off the main actor; completion paths await this so a long
    /// transcript's regex pass can't hitch the UI right as results land.
    func postProcessDetached(_ transcript: Transcript) async -> Transcript {
        let ignored = ignoredSegmentRules
        let findReplace = findReplaceRules
        return await Task.detached(priority: .userInitiated) {
            Self.postProcess(transcript, ignoredRules: ignored, findReplaceRules: findReplace)
        }.value
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
        applyTranscriptEdit(transcript, actionName: String(localized: "Rename Speaker"))
        Task { [peopleStore] in
            for to in nonEmpty.values {
                _ = await peopleStore.recordUsage(name: to)
            }
        }
    }
}
