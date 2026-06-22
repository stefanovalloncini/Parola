import Foundation

public extension Transcript {
    /// Unique speaker labels in first-seen order.
    var uniqueSpeakers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments {
            if let speaker = seg.speaker, !speaker.isEmpty, !seen.contains(speaker) {
                seen.insert(speaker)
                ordered.append(speaker)
            }
        }
        return ordered
    }

    /// Returns a copy with every `speaker == from` rewritten to `to`, at both segment and word level.
    func renamingSpeaker(_ from: String, to newName: String) -> Transcript {
        var copy = self
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return self }
        for i in copy.segments.indices {
            if copy.segments[i].speaker == from {
                copy.segments[i].speaker = target
            }
            if var words = copy.segments[i].words {
                var changed = false
                for j in words.indices where words[j].speaker == from {
                    words[j].speaker = target
                    changed = true
                }
                if changed { copy.segments[i].words = words }
            }
        }
        return copy
    }
}
