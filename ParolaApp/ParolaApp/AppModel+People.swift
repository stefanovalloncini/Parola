import Foundation
import SwiftUI
import ParolaCore

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

    /// The directory in the order every list shows it: most assigned, then most recently used.
    var peopleByUse: [Person] {
        people.sorted {
            $0.usageCount == $1.usageCount ? $0.lastUsedAt > $1.lastUsedAt : $0.usageCount > $1.usageCount
        }
    }

    func mostUsedPeople(limit: Int) -> [Person] {
        Array(peopleByUse.prefix(limit))
    }

    /// The open entry's speaker map. A transcript that isn't in the library carries none.
    var speakerAssignments: [String: UUID] {
        guard let id = selectedEntryID else { return [:] }
        return libraryEntry(id: id)?.speakerAssignments ?? [:]
    }

    func person(forSpeaker label: String) -> Person? {
        guard let id = speakerAssignments[label] else { return nil }
        return person(id: id)
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
        guard await applyAssignment(label: label, to: person) else { return }
        _ = await peopleStore.recordUsage(name: person.name)
        await refreshPeople()
    }

    /// Creates the person (or reuses one already under that name) and assigns the label to them.
    /// Creating them is the use that gets counted, so the assignment adds none of its own.
    func assignSpeaker(label: String, toNewPersonNamed name: String) async {
        let personName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personName.isEmpty else { return }
        let person = await peopleStore.recordUsage(name: personName)
        await refreshPeople()
        await applyAssignment(label: label, to: person)
    }

    @discardableResult
    private func applyAssignment(label: String, to person: Person) async -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = transcript else { return false }
        if trimmed != person.name {
            applyTranscriptEdit(
                current.renamingSpeaker(trimmed, to: person.name),
                actionName: String(localized: "Assign Speaker")
            )
        }
        var map = speakerAssignments
        map.removeValue(forKey: trimmed)
        map[person.name] = person.id
        await writeSpeakerAssignments(map)
        return true
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
        applyTranscriptEdit(updated, actionName: String(localized: "Clear Speaker"))
        var map = speakerAssignments
        map.removeValue(forKey: trimmed)
        await writeSpeakerAssignments(map)
    }

    /// Records who a name stands for without touching the transcript — what a per-segment assign
    /// leaves behind once the label matches a person.
    func recordSpeakerAssignment(label: String, person: Person) async {
        var map = speakerAssignments
        guard map[label] != person.id else { return }
        map[label] = person.id
        await writeSpeakerAssignments(map)
    }

    private func writeSpeakerAssignments(_ map: [String: UUID]) async {
        guard let id = selectedEntryID else { return }
        await writeAssignments(map, to: id)
    }

    // MARK: - The directory's own edits

    func addPerson(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
            await writeAssignments(entry.speakerAssignments.filter { $0.value != id }, to: entry.id)
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
            var map = entry.speakerAssignments
            for name in oldNames { map.removeValue(forKey: name) }
            map[newName] = survivor
            let renames = oldNames.filter { $0 != newName }
            if entry.id == selectedEntryID, let current = transcript {
                var updated = current
                for name in renames { updated = updated.renamingSpeaker(name, to: newName) }
                applyTranscriptEdit(updated, actionName: String(localized: "Rename Person"))
            } else if !renames.isEmpty {
                do {
                    var stored = try await library.load(entry.id).document.transcript
                    for name in renames { stored = stored.renamingSpeaker(name, to: newName) }
                    try await library.updateTranscript(stored, for: entry.id)
                } catch {
                    ParolaLog.error(.library, "person rename not written", Self.entryFields(entry.id, error))
                    continue
                }
            }
            await writeAssignments(map, to: entry.id)
        }
    }

    private func writeAssignments(_ map: [String: UUID], to entryID: LibraryEntry.ID) async {
        do {
            try await library.setSpeakerAssignments(map, for: entryID)
            patchLibraryEntry(id: entryID) { $0.speakerAssignments = map }
        } catch {
            ParolaLog.error(.library, "speaker assignments not written", Self.entryFields(entryID, error))
        }
    }

    nonisolated static func entryFields(_ entryID: LibraryEntry.ID, _ error: any Error) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.error: .error(error)]
        if let uuid = UUID(uuidString: entryID) { fields[.entry] = .id(uuid) }
        return fields
    }

    // MARK: - The Person filter

    /// The one way the library's Person filter changes. Picking a person brings the list forward,
    /// since a filtered list is the only place the rows show.
    func setPersonFilter(_ id: UUID?) {
        guard personFilter != id else { return }
        personFilter = id
        if id != nil, !isBrowsingLibrary { browseAll() }
    }
}
