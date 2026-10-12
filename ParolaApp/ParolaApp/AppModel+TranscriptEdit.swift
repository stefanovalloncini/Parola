import AppKit
import Foundation
import ParolaCore

extension AppModel {
    /// The single seam for user edits: installs the new value, persists, remaps the id-keyed side
    /// maps, and registers an inverse edit with the undo manager unless the caller registers its own.
    func applyTranscriptEdit(
        _ new: Transcript,
        actionName: String,
        textChanged: Bool = true,
        favorites: (old: Set<Int>, new: Set<Int>)? = nil,
        notes: (old: [Int: String], new: [Int: String])? = nil,
        assignments: SpeakerAssignmentEdit? = nil,
        undoable: Bool = true
    ) {
        guard let old = transcript, old != new else { return }
        let resolvedFavorites = favorites ?? (favoriteSegmentIDs, favoriteSegmentIDs)
        let resolvedNotes = notes ?? (segmentNotesByID, segmentNotesByID)
        // Read before the edit lands: the inverse has to restore what the map held a moment ago.
        let inverseAssignments = assignments.map { $0.inverse(of: speakerAssignments) }
        transcript = new
        persistCurrentTranscriptIfLoaded(textChanged: textChanged)
        if resolvedFavorites.new != resolvedFavorites.old { replaceFavorites(resolvedFavorites.new) }
        if resolvedNotes.new != resolvedNotes.old { replaceSegmentNotes(resolvedNotes.new) }
        if let assignments { applySpeakerAssignmentEdit(assignments) }
        guard undoable else { return }
        registerTranscriptUndo(
            restoring: old, translationAfterEdit: new.translation, favorites: resolvedFavorites,
            notes: resolvedNotes, actionName: actionName, textChanged: textChanged, assignments: inverseAssignments
        )
    }

    private func registerTranscriptUndo(
        restoring old: Transcript,
        translationAfterEdit: TranscriptTranslation?,
        favorites: (old: Set<Int>, new: Set<Int>),
        notes: (old: [Int: String], new: [Int: String]),
        actionName: String,
        textChanged: Bool,
        assignments: SpeakerAssignmentEdit?
    ) {
        let entryID = selectedEntryID
        // From the undo closure's perspective this edit's `new` favorites are current; `old` is the restore target.
        let inverseFavorites = (old: favorites.new, new: favorites.old)
        let inverseNotes = (old: notes.new, new: notes.old)
        registerUndoStep(actionName: actionName) { model in
            guard model.selectedEntryID == entryID, let live = model.transcript else { return }
            model.applyTranscriptEdit(
                old.restoring(generatedIn: live, translationAfterEdit: translationAfterEdit),
                actionName: actionName, textChanged: textChanged, favorites: inverseFavorites,
                notes: inverseNotes, assignments: assignments
            )
        }
    }

    func registerUndoStep(actionName: String, _ revert: @escaping @MainActor @Sendable (AppModel) -> Void) {
        guard let undoManager else { return }
        // Only group explicitly when event grouping is off (tests): nesting inside the window's per-event group would leave that group unnamed, and the Edit menu title reads the top-level group's name.
        let opensGroup = !undoManager.groupsByEvent && !undoManager.isUndoing && !undoManager.isRedoing
            && undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            // Undo always fires on the thread that calls undo()/redo(), which is the main thread here.
            MainActor.assumeIsolated { revert(model) }
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

    /// A click plays from the segment when there is audio; without it, the click still chooses the segment for the menus.
    func chooseSegment(_ segment: TranscriptSegment) {
        if player != nil {
            seek(to: segment)
        } else {
            currentSegmentID = segment.id
        }
    }

    private var focusedSegment: TranscriptSegment? {
        guard let id = focusedSegmentIDForCommands else { return nil }
        return transcript?.segments.first { $0.id == id }
    }

    /// Only a card can hold the edit field, so from Paragraphs or another pane the segments come forward first.
    func editFocusedSegment() {
        guard let segment = focusedSegment else { return }
        if transcriptDisplayMode != .segments || transcriptPaneMode != .transcript {
            showTranscriptLayout(.segments)
        }
        pendingRevealSegmentID = segment.id
        pendingSegmentEditID = segment.id
    }

    func noteFocusedSegment() {
        guard let segment = focusedSegment else { return }
        beginEditingNote(for: segment)
    }

    func deleteFocusedSegment() {
        guard let segment = focusedSegment else { return }
        deleteSegment(id: segment.id)
    }

    func splitFocusedSegment() {
        guard let segment = focusedSegment else { return }
        splitAtPlayingWord(segment)
    }

    func mergeFocusedSegmentWithNext() {
        guard let segment = focusedSegment else { return }
        mergeSegmentWithNext(id: segment.id)
    }

    var focusedSegmentHasNext: Bool {
        guard let id = focusedSegmentIDForCommands, let last = transcript?.segments.last else { return false }
        return last.id != id
    }

    /// The playing word when this is the current segment and it has word times; the middle otherwise.
    func splitAtPlayingWord(_ segment: TranscriptSegment) {
        if segment.id == currentSegmentID,
           let words = segment.words,
           let wordID = currentWordID,
           let index = words.firstIndex(where: { $0.id == wordID }) {
            splitSegment(id: segment.id, atWordIndex: index)
        } else {
            splitSegment(id: segment.id, atFraction: 0.5)
        }
    }

    func deleteSegment(id: TranscriptSegment.ID) {
        guard var t = transcript else { return }
        if currentSegmentID == id { currentSegmentID = nil }
        t.segments.removeAll { $0.id == id }
        t.translation = t.translation?.afterDelete(of: id)
        let favorites = favoriteSegmentIDs
        let notes = segmentNotesByID
        applyTranscriptEdit(
            t,
            actionName: String(localized: "Delete Segment"),
            favorites: (favorites, FavoriteRemap.afterDelete(favorites, of: id)),
            notes: (notes, SegmentNoteRemap.afterDelete(notes, of: id))
        )
    }

    func assignSpeaker(_ name: String?, toSegmentID id: TranscriptSegment.ID) {
        // Only a name the directory already knows: picking a raw diarizer label off the submenu
        // must not mint a person out of "SPEAKER_01".
        let known = name.flatMap { person(named: $0) }
        guard applySegmentSpeaker(name, toSegmentID: id, recording: known) != nil, let known else { return }
        Task { [peopleStore] in
            _ = await peopleStore.recordUsage(name: known.name)
            await refreshPeople()
        }
    }

    /// Writes one segment's speaker, and its words'. Returns the new name when it changed, so the
    /// caller decides what the people directory should make of it.
    @discardableResult
    func applySegmentSpeaker(
        _ name: String?,
        toSegmentID id: TranscriptSegment.ID,
        recording person: Person? = nil
    ) -> String? {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let previous = t.segments[idx].speaker
        t.segments[idx].speaker = speaker
        if var words = t.segments[idx].words, words.contains(where: { $0.speaker != nil }) {
            for j in words.indices { words[j].speaker = speaker }
            t.segments[idx].words = words
        }
        var assignment: SpeakerAssignmentEdit?
        if let speaker, let person, speakerAssignments[speaker] != person.id {
            assignment = SpeakerAssignmentEdit(assign: [speaker: person.id])
        }
        if t == transcript {
            if let assignment { applySpeakerAssignmentEdit(assignment) }
        } else {
            applyTranscriptEdit(
                t, actionName: String(localized: "Assign Speaker"), textChanged: false, assignments: assignment
            )
        }
        guard let speaker, speaker != previous else { return nil }
        return speaker
    }

    func splitSegment(id: TranscriptSegment.ID, atWordIndex index: Int) {
        guard var t = transcript else { return }
        guard let split = SegmentSurgery.split(segments: t.segments, id: id, atWordIndex: index) else { return }
        t.segments = split.segments
        t.translation = t.translation?.afterSplit(of: id, into: split.firstID)
        let favorites = favoriteSegmentIDs
        let notes = segmentNotesByID
        applyTranscriptEdit(
            t,
            actionName: String(localized: "Split Segment"),
            favorites: (favorites, FavoriteRemap.afterSplit(favorites, of: id, into: split.firstID)),
            notes: (notes, SegmentNoteRemap.afterSplit(notes, of: id, into: split.firstID))
        )
    }

    func splitSegment(id: TranscriptSegment.ID, atFraction fraction: Double) {
        guard var t = transcript else { return }
        guard let split = SegmentSurgery.split(segments: t.segments, id: id, atFraction: fraction) else { return }
        t.segments = split.segments
        t.translation = t.translation?.afterSplit(of: id, into: split.firstID)
        let favorites = favoriteSegmentIDs
        let notes = segmentNotesByID
        applyTranscriptEdit(
            t,
            actionName: String(localized: "Split Segment"),
            favorites: (favorites, FavoriteRemap.afterSplit(favorites, of: id, into: split.firstID)),
            notes: (notes, SegmentNoteRemap.afterSplit(notes, of: id, into: split.firstID))
        )
    }

    func mergeSegmentWithNext(id: TranscriptSegment.ID) {
        guard var t = transcript,
              let position = t.segments.firstIndex(where: { $0.id == id }), position + 1 < t.segments.count,
              let segments = SegmentSurgery.mergeWithNext(segments: t.segments, id: id) else { return }
        let nextID = t.segments[position + 1].id
        t.segments = segments
        t.translation = t.translation?.afterMerge(of: id, with: nextID)
        let favorites = favoriteSegmentIDs
        let notes = segmentNotesByID
        applyTranscriptEdit(
            t,
            actionName: String(localized: "Merge Segments"),
            favorites: (favorites, FavoriteRemap.afterMerge(favorites, of: id, with: nextID)),
            notes: (notes, SegmentNoteRemap.afterMerge(notes, of: id, with: nextID))
        )
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

extension Transcript {
    /// What undo and redo put back: this snapshot's segments, with the AI results, chat and translation made since.
    func restoring(generatedIn live: Transcript, translationAfterEdit: TranscriptTranslation?) -> Transcript {
        var restored = self
        restored.summary = live.summary
        restored.chapters = live.chapters
        restored.chatHistory = live.chatHistory
        restored.actionItems = live.actionItems
        if live.translation != translationAfterEdit {
            restored.translation = live.translation?.carried(from: live.segments, onto: segments)
        }
        return restored
    }
}

extension TranscriptTranslation {
    /// Carries a translation made after an edit across its undo: shared ids keep their text, and a split's halves rejoin or part again.
    func carried(from liveSegments: [TranscriptSegment], onto restoredSegments: [TranscriptSegment]) -> TranscriptTranslation {
        let restoredIDs = Set(restoredSegments.map(\.id))
        let liveIDs = Set(liveSegments.map(\.id))
        let gone = liveSegments.map(\.id).filter { !restoredIDs.contains($0) }
        let back = restoredSegments.map(\.id).filter { !liveIDs.contains($0) }
        var out = self
        out.segments = segments.filter { restoredIDs.contains($0.key) }
        if back.count == 1, gone.count > 1 {
            let joined = gone.compactMap { segments[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty { out.segments[back[0]] = joined }
        } else if gone.count == 1, let first = back.first, let text = segments[gone[0]] {
            out.segments[first] = text
        }
        return out
    }
}
