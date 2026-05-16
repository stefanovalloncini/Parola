import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadIgnoredSegmentRules() {
        guard let data = UserDefaults.standard.data(forKey: "ignoredSegmentRules"),
              let rules = try? JSONDecoder().decode([IgnoredSegmentRule].self, from: data) else { return }
        ignoredSegmentRules = rules
    }

    func saveIgnoredSegmentRules() {
        if let data = try? JSONEncoder().encode(ignoredSegmentRules) {
            UserDefaults.standard.set(data, forKey: "ignoredSegmentRules")
        }
    }

    func loadFindReplaceRules() {
        guard let data = UserDefaults.standard.data(forKey: "findReplaceRules"),
              let rules = try? JSONDecoder().decode([FindReplaceRule].self, from: data) else { return }
        findReplaceRules = rules
    }

    func saveFindReplaceRules() {
        if let data = try? JSONEncoder().encode(findReplaceRules) {
            UserDefaults.standard.set(data, forKey: "findReplaceRules")
        }
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
