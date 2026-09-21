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

    /// The Speakers sheet's bulk rename: one label at a time through the entry point that keeps
    /// the entry's speaker map in step.
    func applySpeakerRenames(_ renames: [String: String]) {
        for (from, to) in renames {
            renameSpeakerLabel(from, to: to)
        }
    }
}
