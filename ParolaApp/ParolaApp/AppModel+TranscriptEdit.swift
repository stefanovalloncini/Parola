import AppKit
import Foundation
import ParolaCore

extension AppModel {
    /// The single seam for user edits: installs the new value, persists, remaps favorites, and registers an inverse edit with the undo manager.
    func applyTranscriptEdit(
        _ new: Transcript,
        actionName: String,
        textChanged: Bool = true,
        favorites: (old: Set<Int>, new: Set<Int>)? = nil,
        assignments: SpeakerAssignmentEdit? = nil
    ) {
        guard let old = transcript, old != new else { return }
        let resolvedFavorites = favorites ?? (favoriteSegmentIDs, favoriteSegmentIDs)
        // Read before the edit lands: the inverse has to restore what the map held a moment ago.
        let inverseAssignments = assignments.map { $0.inverse(of: speakerAssignments) }
        transcript = new
        persistCurrentTranscriptIfLoaded(textChanged: textChanged)
        if resolvedFavorites.new != resolvedFavorites.old { replaceFavorites(resolvedFavorites.new) }
        if let assignments { applySpeakerAssignmentEdit(assignments) }
        registerTranscriptUndo(
            restoring: old, favorites: resolvedFavorites, actionName: actionName, textChanged: textChanged,
            assignments: inverseAssignments
        )
    }

    private func registerTranscriptUndo(
        restoring old: Transcript,
        favorites: (old: Set<Int>, new: Set<Int>),
        actionName: String,
        textChanged: Bool,
        assignments: SpeakerAssignmentEdit?
    ) {
        guard let undoManager else { return }
        let entryID = selectedEntryID
        // From the undo closure's perspective this edit's `new` favorites are current; `old` is the restore target.
        let inverseFavorites = (old: favorites.new, new: favorites.old)
        // Only group explicitly when event grouping is off (tests): nesting inside the window's per-event group would leave that group unnamed, and the Edit menu title reads the top-level group's name.
        let opensGroup = !undoManager.groupsByEvent && !undoManager.isUndoing && !undoManager.isRedoing
            && undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            // Undo always fires on the thread that calls undo()/redo(), which is the main thread here.
            MainActor.assumeIsolated {
                guard model.selectedEntryID == entryID else { return }
                model.applyTranscriptEdit(
                    old, actionName: actionName, textChanged: textChanged, favorites: inverseFavorites,
                    assignments: assignments
                )
            }
        }
        undoManager.setActionName(actionName)
        if opensGroup { undoManager.endUndoGrouping() }
    }

    func editSegment(id: TranscriptSegment.ID, newText: String) {
        guard var t = transcript else { return }
        guard let idx = t.segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != t.segments[idx].text else { return }
        t.segments[idx].text = trimmed
        t.segments[idx].words = nil
        applyTranscriptEdit(t, actionName: String(localized: "Edit Segment"))
    }

    func deleteSegment(id: TranscriptSegment.ID) {
        guard var t = transcript else { return }
        t.segments.removeAll { $0.id == id }
        t.translation = t.translation?.afterDelete(of: id)
        let favorites = favoriteSegmentIDs
        let newFavorites = FavoriteRemap.afterDelete(favorites, of: id)
        applyTranscriptEdit(t, actionName: String(localized: "Delete Segment"), favorites: (favorites, newFavorites))
    }

    func assignSpeaker(_ name: String?, toSegmentID id: TranscriptSegment.ID) {
        guard let speaker = applySegmentSpeaker(name, toSegmentID: id) else { return }
        // Only a name the directory already knows: picking a raw diarizer label off the submenu
        // must not mint a person out of "SPEAKER_01".
        Task { [peopleStore] in
            guard await peopleStore.person(named: speaker) != nil else { return }
            let person = await peopleStore.recordUsage(name: speaker)
            await recordSpeakerAssignment(label: speaker, person: person)
            await refreshPeople()
        }
    }

    /// Writes one segment's speaker, and its words'. Returns the new name when it changed, so the
    /// caller decides what the people directory should make of it.
    @discardableResult
    func applySegmentSpeaker(_ name: String?, toSegmentID id: TranscriptSegment.ID) -> String? {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let previous = t.segments[idx].speaker
        t.segments[idx].speaker = speaker
        if var words = t.segments[idx].words, words.contains(where: { $0.speaker != nil }) {
            for j in words.indices { words[j].speaker = speaker }
            t.segments[idx].words = words
        }
        applyTranscriptEdit(t, actionName: String(localized: "Assign Speaker"), textChanged: false)
        guard let speaker, speaker != previous else { return nil }
        return speaker
    }

    func splitSegment(id: TranscriptSegment.ID, atWordIndex index: Int) {
        guard var t = transcript else { return }
        guard let split = SegmentSurgery.split(segments: t.segments, id: id, atWordIndex: index) else { return }
        t.segments = split.segments
        t.translation = t.translation?.afterSplit(of: id, into: split.firstID)
        let favorites = favoriteSegmentIDs
        let newFavorites = FavoriteRemap.afterSplit(favorites, of: id, into: split.firstID)
        applyTranscriptEdit(t, actionName: String(localized: "Split Segment"), favorites: (favorites, newFavorites))
    }

    func splitSegment(id: TranscriptSegment.ID, atFraction fraction: Double) {
        guard var t = transcript else { return }
        guard let split = SegmentSurgery.split(segments: t.segments, id: id, atFraction: fraction) else { return }
        t.segments = split.segments
        t.translation = t.translation?.afterSplit(of: id, into: split.firstID)
        let favorites = favoriteSegmentIDs
        let newFavorites = FavoriteRemap.afterSplit(favorites, of: id, into: split.firstID)
        applyTranscriptEdit(t, actionName: String(localized: "Split Segment"), favorites: (favorites, newFavorites))
    }

    func mergeSegmentWithNext(id: TranscriptSegment.ID) {
        guard var t = transcript,
              let position = t.segments.firstIndex(where: { $0.id == id }), position + 1 < t.segments.count,
              let segments = SegmentSurgery.mergeWithNext(segments: t.segments, id: id) else { return }
        let nextID = t.segments[position + 1].id
        t.segments = segments
        t.translation = t.translation?.afterMerge(of: id, with: nextID)
        let favorites = favoriteSegmentIDs
        let newFavorites = FavoriteRemap.afterMerge(favorites, of: id, with: nextID)
        applyTranscriptEdit(t, actionName: String(localized: "Merge Segments"), favorites: (favorites, newFavorites))
    }

    func nudgeSegmentStart(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeStart(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        applyTranscriptEdit(t, actionName: String(localized: "Adjust Timing"), textChanged: false)
    }

    func nudgeSegmentEnd(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeEnd(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        applyTranscriptEdit(t, actionName: String(localized: "Adjust Timing"), textChanged: false)
    }
}
