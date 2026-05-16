import Foundation

public extension Transcript {
    /// Unique speaker labels in first-seen order.
    var uniqueSpeakers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments {
            if let speaker = seg.speaker, !seen.contains(speaker) {
                seen.insert(speaker)
                ordered.append(speaker)
            }
        }
        return ordered
    }

    /// Returns a copy with every segment whose `speaker == from` rewritten to `to`.
    func renamingSpeaker(_ from: String, to newName: String) -> Transcript {
        var copy = self
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return self }
        for i in copy.segments.indices where copy.segments[i].speaker == from {
            copy.segments[i].speaker = target
        }
        return copy
    }
}
