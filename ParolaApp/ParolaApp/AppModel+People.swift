import Foundation
import SwiftUI
import ParolaCore

/// Keys to set or drop in an entry's speaker map. Edits travel as a transform, never as a whole
/// map read somewhere else, so two assignments in flight can't drop each other's key.
struct SpeakerAssignmentEdit: Equatable, Sendable {
    var assign: [String: UUID] = [:]
    var clear: [String] = []

    var isEmpty: Bool { assign.isEmpty && clear.isEmpty }

    func apply(to map: inout [String: UUID]) {
        for key in clear { map.removeValue(forKey: key) }
        for (key, id) in assign { map[key] = id }
    }

    /// What puts `map` back the way it was, so undo and redo both re-key it.
    func inverse(of map: [String: UUID]) -> SpeakerAssignmentEdit {
        var undo = SpeakerAssignmentEdit()
        for key in Set(assign.keys).union(clear) {
            if let previous = map[key] { undo.assign[key] = previous } else { undo.clear.append(key) }
        }
        return undo
    }
}

extension AppModel {

    // MARK: - The directory

    /// Mirrors the store into `people`. Awaited by every mutation, so a caller that returns has
    /// the directory the store holds.
    func refreshPeople() async {
        let stored = await peopleStore.people
        if stored != people { people = stored }
    }

    func person(id: UUID) -> Person? {
        people.first { $0.id == id }
    }

    /// The person marked "This Is Me"; the mark is kept in People.json, with the people themselves.
    var mePerson: Person? {
        people.first(where: \.isMe)
    }

    func setMePerson(_ id: UUID?) async {
        await peopleStore.markAsMe(id)
        await refreshPeople()
    }

    /// A transcript whose "Me" took your name stands for you in its entry, as a speaker you assigned would.
    func assignMePerson(in entryID: LibraryEntry.ID, transcript: Transcript) {
        guard let me = mePerson, transcript.segments.contains(where: { $0.speaker == me.name }) else { return }
        let edit = SpeakerAssignmentEdit(assign: [me.name: me.id])
        patchLibraryEntry(id: entryID) { edit.apply(to: &$0.speakerAssignments) }
        scheduleAssignmentWrite(for: entryID) { edit.apply(to: &$0) }
    }

    /// The person under a name, matched the way the store matches it.
    func person(named name: String) -> Person? {
        let key = Person.normalizedName(name)
        guard !key.isEmpty else { return nil }
        return people.first { Person.normalizedName($0.name) == key }
    }

    /// The labels that stand for this person right now, rather than every assignment ever made.
    func usageCount(of person: Person) -> Int {
        personUsageCounts[person.id] ?? 0
    }

    /// The transcripts that stand for this person, the number their own page counts.
    func transcriptCount(of person: Person) -> Int {
        personTranscriptCounts[person.id] ?? 0
    }

    static func personTranscriptCounts(in entries: [LibraryEntry]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for entry in entries {
            for id in entry.personIDs { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Opens the directory with the rename or the delete already asked, for a person picked outside it.
    func managePerson(_ request: PeopleSheetRequest) {
        peopleSheetRequest = request
        showingPeopleSheet = true
    }

    static func personUsageCounts(in entries: [LibraryEntry]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for entry in entries {
            for id in entry.speakerAssignments.values { counts[id, default: 0] += 1 }
        }
        return counts
    }

    func mostUsedPeople(limit: Int) -> [Person] {
        Array(peopleByUse.prefix(limit))
    }

    /// A people menu's first `limit` by use, and everyone past them by name, so no one drops off a long directory.
    func personMenuChoices(excluding names: Set<String> = [], limit: Int) -> (top: [Person], more: [Person]) {
        let top = Array(peopleByUse.lazy.filter { !names.contains($0.name) }.prefix(limit))
        let topIDs = Set(top.map(\.id))
        let more = peopleByName.filter { !names.contains($0.name) && !topIDs.contains($0.id) }
        return (top, more)
    }

    /// A segment's speaker menu: this transcript's speakers, then the people who aren't one of them.
    func segmentSpeakerChoices(peopleLimit: Int) -> (speakers: [String], people: (top: [Person], more: [Person])) {
        let speakers = transcriptSpeakers
        return (speakers, personMenuChoices(excluding: Set(speakers), limit: peopleLimit))
    }

    /// The open entry's speaker map. A transcript that isn't in the library carries none.
    var speakerAssignments: [String: UUID] { selectedEntrySpeakerAssignments }

    func person(forSpeaker label: String) -> Person? {
        guard let id = speakerAssignments[label] else { return nil }
        return person(id: id)
    }

    /// The one lookup every speaker-colour surface shares — the filter chip, the card, the heading, the inspector.
    func speakerColor(for label: String) -> Color {
        DS.speakerColor(for: label, colorIndex: person(forSpeaker: label)?.colorIndex)
    }

    /// The colour each speaker label wears: the person's when it has one, its own hash otherwise.
    var speakerColorIndices: [String: Int] {
        var indices: [String: Int] = [:]
        for (label, id) in speakerAssignments {
            guard let person = person(id: id) else { continue }
            indices[label] = person.colorIndex
        }
        return indices
    }

    /// How many segments carry each speaker label, in the order the labels first appear.
    var speakerSegmentCounts: [(label: String, count: Int)] {
        guard let transcript else { return [] }
        var counts: [String: Int] = [:]
        for segment in transcript.segments {
            guard let speaker = segment.speaker, !speaker.isEmpty else { continue }
            counts[speaker, default: 0] += 1
        }
        return transcriptSpeakers.map { (label: $0, count: counts[$0] ?? 0) }
    }

    func entries(withPerson id: UUID) -> [LibraryEntry] {
        libraryEntries.filter { $0.personIDs.contains(id) }
    }

    // MARK: - Assigning a speaker

    /// The one way a speaker label becomes a person: every segment (and word) carrying the label
    /// takes the person's name, and the open entry records whose name it now is.
    func assignSpeaker(label: String, to person: Person) async {
        guard applyAssignment(label: label, to: person) else { return }
        _ = await peopleStore.recordUsage(name: person.name)
        await refreshPeople()
        await awaitSpeakerAssignmentWrites()
    }

    /// Creates the person (or reuses one already under that name) and assigns the label to them.
    /// Creating them is the use that gets counted, so the assignment adds none of its own.
    func assignSpeaker(label: String, toNewPersonNamed name: String) async {
        let personName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personName.isEmpty else { return }
        let person = await peopleStore.recordUsage(name: personName)
        await refreshPeople()
        applyAssignment(label: label, to: person)
        await awaitSpeakerAssignmentWrites()
    }

    /// Names one segment's speaker and makes a person of that name. The submenu's plain picks go
    /// through ``assignSpeaker(_:toSegmentID:)`` instead, which mints nobody.
    func assignSegment(_ id: TranscriptSegment.ID, toNewPersonNamed name: String) async {
        let personName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personName.isEmpty else { return }
        let person = await peopleStore.recordUsage(name: personName)
        await refreshPeople()
        applySegmentSpeaker(person.name, toSegmentID: id, recording: person)
        await awaitSpeakerAssignmentWrites()
    }

    @discardableResult
    private func applyAssignment(label: String, to person: Person) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = transcript else { return false }
        guard trimmed != person.name || speakerAssignments[person.name] != person.id else { return false }
        let edit = SpeakerAssignmentEdit(
            assign: [person.name: person.id],
            clear: trimmed == person.name ? [] : [trimmed]
        )
        let renamed = current.renamingSpeaker(trimmed, to: person.name)
        if renamed != current {
            applyTranscriptEdit(renamed, actionName: String(localized: "Assign Speaker"), assignments: edit)
        } else {
            applySpeakerAssignmentEdit(edit)
        }
        return true
    }

    /// Whether ``renameSpeakerLabel(_:to:)`` would do anything, so a sheet that changed nothing
    /// leaves no empty undo step behind.
    func renamesSomething(_ label: String, to newName: String) -> Bool {
        let from = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return false }
        return transcript?.uniqueSpeakers.contains(from) ?? false
    }

    /// The one way a speaker label's text changes: the segments and the entry's map move together, inside the same undo step.
    func renameSpeakerLabel(_ label: String, to newName: String) {
        let from = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to, let current = transcript else { return }
        var edit: SpeakerAssignmentEdit?
        var used: Person?
        if let assigned = speakerAssignments[from] {
            // A label that already stands for someone keeps pointing at them under its new text.
            edit = SpeakerAssignmentEdit(assign: [to: assigned], clear: [from])
        } else if let existing = person(named: to) {
            // Renaming a label to someone the directory knows is an assignment under another name.
            edit = SpeakerAssignmentEdit(assign: [to: existing.id], clear: [from])
            used = existing
        }
        let renamed = current.renamingSpeaker(from, to: to)
        guard renamed != current else { return }
        applyTranscriptEdit(renamed, actionName: String(localized: "Rename Speaker"), assignments: edit)
        guard let used else { return }
        Task { [peopleStore] in
            // The stored spelling, not the typed one: counting a use must not rename the person.
            _ = await peopleStore.recordUsage(name: used.name)
            await refreshPeople()
        }
    }

    /// Drops the speaker from every segment carrying the label, and the label from the map.
    func clearSpeaker(label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var updated = transcript else { return }
        var changed = false
        for index in updated.segments.indices where updated.segments[index].speaker == trimmed {
            updated.segments[index].speaker = nil
            if var words = updated.segments[index].words {
                for wordIndex in words.indices { words[wordIndex].speaker = nil }
                updated.segments[index].words = words
            }
            changed = true
        }
        guard changed else { return }
        applyTranscriptEdit(
            updated,
            actionName: String(localized: "Clear Speaker"),
            assignments: SpeakerAssignmentEdit(clear: [trimmed])
        )
        await awaitSpeakerAssignmentWrites()
    }

    /// Applies one edit to the open entry: to the cached map now, to the bundle next.
    func applySpeakerAssignmentEdit(_ edit: SpeakerAssignmentEdit) {
        guard !edit.isEmpty, let id = selectedEntryID else { return }
        patchLibraryEntry(id: id) { edit.apply(to: &$0.speakerAssignments) }
        scheduleAssignmentWrite(for: id) { edit.apply(to: &$0) }
    }

    // MARK: - The directory's own edits

    func addPerson(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await peopleStore.person(named: trimmed) == nil else { return }
        _ = await peopleStore.recordUsage(name: trimmed)
        await refreshPeople()
    }

    /// Renames a person and rewrites the name into every entry that stands for them. The library
    /// rewrite is not undoable; the open transcript's edit is.
    func renamePerson(_ id: UUID, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, person(id: id)?.name != trimmed else { return }
        let targets = entries(withPerson: id)
        guard let renamed = await peopleStore.rename(id, to: trimmed) else { return }
        await refreshPeople()
        await rewriteEntries(targets, from: id, toName: renamed.name, keeping: renamed.id)
    }

    /// Folds one person into another, rewriting the source's name to the target's everywhere.
    func mergePerson(_ source: UUID, into target: UUID) async {
        guard source != target, person(id: source) != nil, person(id: target) != nil else { return }
        let targets = entries(withPerson: source)
        guard let merged = await peopleStore.merge(source, into: target) else { return }
        await refreshPeople()
        await rewriteEntries(targets, from: source, toName: merged.name, keeping: merged.id)
    }

    /// Forgets a person. The names they were assigned to stay in the transcripts; only the map
    /// entries go.
    func deletePerson(_ id: UUID) async {
        let targets = entries(withPerson: id)
        guard await peopleStore.delete(id) else { return }
        if personFilter == id { personFilter = nil }
        await refreshPeople()
        for entry in targets {
            await mutateAssignments(for: entry.id) { map in
                map = map.filter { $0.value != id }
            }
        }
    }

    // MARK: - Cascades

    /// Rewrites one person's name across the entries that stand for them, one entry at a time.
    /// A failure is logged and the loop moves on; there is no progress UI.
    private func rewriteEntries(
        _ entries: [LibraryEntry],
        from personID: UUID,
        toName newName: String,
        keeping survivor: UUID
    ) async {
        for entry in entries {
            let oldNames = entry.speakerAssignments.filter { $0.value == personID }.map(\.key)
            let renames = oldNames.filter { $0 != newName }
            if entry.id == selectedEntryID, let current = transcript {
                var updated = current
                for name in renames { updated = updated.renamingSpeaker(name, to: newName) }
                let edit = SpeakerAssignmentEdit(assign: [newName: survivor], clear: renames)
                if updated != current {
                    applyTranscriptEdit(updated, actionName: String(localized: "Rename Person"), assignments: edit)
                } else {
                    applySpeakerAssignmentEdit(edit)
                }
                await awaitSpeakerAssignmentWrites()
                continue
            }
            if !renames.isEmpty {
                do {
                    try await library.mutateTranscript(for: entry.id) { stored in
                        for name in renames { stored = stored.renamingSpeaker(name, to: newName) }
                    }
                } catch {
                    ParolaLog.error(.library, "person rename not written", Self.entryFields(entry.id, error))
                    continue
                }
            }
            await mutateAssignments(for: entry.id) { map in
                map = map.filter { $0.value != personID }
                map[newName] = survivor
            }
        }
    }

    // MARK: - Writing the map

    private func mutateAssignments(
        for entryID: LibraryEntry.ID,
        _ transform: @escaping @Sendable (inout [String: UUID]) -> Void
    ) async {
        scheduleAssignmentWrite(for: entryID, transform)
        await awaitSpeakerAssignmentWrites()
    }

    /// Queues one map transform behind the last, so the bundle sees them in the order they were made.
    private func scheduleAssignmentWrite(
        for entryID: LibraryEntry.ID,
        _ transform: @escaping @Sendable (inout [String: UUID]) -> Void
    ) {
        let previous = speakerAssignmentWriteTask
        speakerAssignmentWriteTask = Task { [library] in
            await previous?.value
            do {
                let updated = try await library.mutateSpeakerAssignments(for: entryID, transform)
                patchLibraryEntry(id: entryID) { $0.speakerAssignments = updated }
            } catch {
                ParolaLog.error(.library, "speaker assignments not written", Self.entryFields(entryID, error))
            }
        }
    }

    func awaitSpeakerAssignmentWrites() async {
        await speakerAssignmentWriteTask?.value
    }

    static func entryFields(_ entryID: LibraryEntry.ID, _ error: any Error) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.error: .error(error)]
        if let uuid = UUID(uuidString: entryID) { fields[.entry] = .id(uuid) }
        return fields
    }

    // MARK: - The Person filter

    /// A sidebar or bridge destination: shows everything the person has, and re-navigates unless that's already on screen.
    func browsePerson(_ id: UUID?) {
        guard let id else {
            guard personFilter != nil else { return }
            personFilter = nil
            return
        }
        guard SidebarSelection.destination(of: sidebarPage) != .person(id) else { return }
        leaveFailedPhase()
        browseAll()
        personFilter = id
    }
}
