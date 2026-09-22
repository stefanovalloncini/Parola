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
        renamingSpeakers([from: newName])
    }

    /// Returns a copy with every speaker rewritten through `map` in one pass. Each label is looked
    /// up once against what it was, so `["A": "B", "B": "C"]` cannot chain A into C.
    func renamingSpeakers(_ map: [String: String]) -> Transcript {
        var targets: [String: String] = [:]
        for (from, newName) in map {
            let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            targets[from] = target
        }
        guard !targets.isEmpty else { return self }
        var copy = self
        for i in copy.segments.indices {
            if let speaker = copy.segments[i].speaker, let target = targets[speaker] {
                copy.segments[i].speaker = target
            }
            if var words = copy.segments[i].words {
                var changed = false
                for j in words.indices {
                    guard let speaker = words[j].speaker, let target = targets[speaker] else { continue }
                    words[j].speaker = target
                    changed = true
                }
                if changed { copy.segments[i].words = words }
            }
        }
        return copy
    }
}
