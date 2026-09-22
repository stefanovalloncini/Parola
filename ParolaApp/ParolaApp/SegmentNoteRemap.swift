import Foundation

/// Moves segment notes with the edit that renumbered the segments they hang off, the way
/// `FavoriteRemap` moves stars.
enum SegmentNoteRemap {
    /// The leading half keeps the note: it starts where the segment the note was written against did.
    static func afterSplit(_ notes: [Int: String], of id: Int, into firstID: Int) -> [Int: String] {
        guard let note = notes[id] else { return notes }
        var out = notes
        out.removeValue(forKey: id)
        out[firstID] = note
        return out
    }

    /// The surviving segment keeps its note; the absorbed one's note follows after a blank line.
    static func afterMerge(_ notes: [Int: String], of id: Int, with nextID: Int) -> [Int: String] {
        var out = notes
        let absorbed = out.removeValue(forKey: nextID)
        switch (out[id], absorbed) {
        case let (kept?, absorbed?): out[id] = kept + "\n\n" + absorbed
        case let (nil, absorbed?): out[id] = absorbed
        default: break
        }
        return out
    }

    static func afterDelete(_ notes: [Int: String], of id: Int) -> [Int: String] {
        var out = notes
        out.removeValue(forKey: id)
        return out
    }
}
