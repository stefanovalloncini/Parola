import Foundation
import ParolaCore

/// The AI runs in flight, each owned by the entry that asked and landing there whatever is on screen.
@MainActor
@Observable
final class AIJobRegistry {
    enum Kind: Hashable, Sendable {
        case summary
        case chapters
        case actionItems
        case prompt
    }

    struct Key: Hashable, Sendable {
        var entryID: LibraryEntry.ID?
        let kind: Kind
    }

    private var keys: [UUID: Key] = [:]
    @ObservationIgnored private var runs: [UUID: any Sendable] = [:]
    @ObservationIgnored private var cancels: [UUID: @MainActor () -> Void] = [:]

    func isRunning(_ kind: Kind, for entryID: LibraryEntry.ID?) -> Bool {
        keys.values.contains(Key(entryID: entryID, kind: kind))
    }

    /// Runs `work` unless the kind already runs for the entry; `land`/`fail` get the owner at the end, a cancelled run neither.
    @discardableResult
    func start<Output: Sendable>(
        _ kind: Kind,
        for entryID: LibraryEntry.ID?,
        work: @escaping @Sendable () async throws -> Output,
        land: @escaping @MainActor (Output, LibraryEntry.ID?) async -> Void,
        fail: @escaping @MainActor (any Error, LibraryEntry.ID?) -> Void
    ) -> Task<Output, any Error>? {
        guard !isRunning(kind, for: entryID) else { return nil }
        let id = UUID()
        let run = Task { try await work() }
        keys[id] = Key(entryID: entryID, kind: kind)
        runs[id] = run
        cancels[id] = { run.cancel() }
        Task { [weak self] in
            let outcome = await run.result
            guard let self, let owner = self.keys[id] else { return }
            switch outcome {
            case .success(let output):
                await land(output, owner.entryID)
            case .failure(let error):
                if !(error is CancellationError) { fail(error, owner.entryID) }
            }
            self.finish(id)
        }
        return run
    }

    /// The run of `kind` in flight for the entry, to wait on instead of starting another.
    func running<Output: Sendable>(_ kind: Kind, for entryID: LibraryEntry.ID?, as output: Output.Type) -> Task<Output, any Error>? {
        let key = Key(entryID: entryID, kind: kind)
        guard let id = keys.first(where: { $0.value == key })?.key else { return nil }
        return runs[id] as? Task<Output, any Error>
    }

    func cancel(_ kind: Kind, for entryID: LibraryEntry.ID?) {
        let key = Key(entryID: entryID, kind: kind)
        for (id, owner) in keys where owner == key { drop(id) }
    }

    /// The entry was trashed or its transcript replaced, so nothing still running for it may land.
    func cancelAll(for entryID: LibraryEntry.ID) {
        for (id, owner) in keys where owner.entryID == entryID { drop(id) }
    }

    /// Runs asked for before their transcript was saved now belong to the entry it was saved as.
    func adoptUnsaved(as entryID: LibraryEntry.ID) {
        for (id, owner) in keys where owner.entryID == nil { keys[id]?.entryID = entryID }
    }

    /// An unsaved transcript left the screen for good, so its runs have nowhere to land.
    func cancelUnsaved() {
        for (id, owner) in keys where owner.entryID == nil { drop(id) }
    }

    private func drop(_ id: UUID) {
        cancels.removeValue(forKey: id)?()
        finish(id)
    }

    private func finish(_ id: UUID) {
        keys[id] = nil
        runs[id] = nil
        cancels[id] = nil
    }
}
