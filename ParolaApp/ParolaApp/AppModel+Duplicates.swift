import Foundation
import ParolaCore

/// The import the "Already in your library" sheet is holding up, and the entry it matched.
struct DuplicateImport: Identifiable, Sendable, Equatable {
    let entryID: String
    let entryTitle: String
    let modelName: String
    let createdAt: Date
    let durationSeconds: Double?
    let fileURL: URL
    let digest: String
    let translateOverride: Bool?

    var id: String { entryID + fileURL.path }
}

extension AppModel {

    /// Hashes the file first and holds the run when the library already has those exact bytes. A
    /// digest that can't be had — unreadable file, read past its deadline — starts the run anyway.
    func startFileImport(fileURL: URL, translateOverride: Bool?) {
        duplicateCheckTask?.cancel()
        let deadline = fileReadDeadline
        duplicateCheckTask = Task { [weak self] in
            guard let self else { return }
            // The user is waiting on this hash, so it gets the same budget as the header probe
            // rather than one that scales with the file: a file too big to hash in time simply
            // skips the check, and the bundle picks up its digest when the library writes it.
            let digest = await SourceDigest.digest(of: fileURL, deadline: deadline)
            var existing: LibraryEntry?
            if let digest { existing = await self.library.findEntry(digest: digest) }
            guard !Task.isCancelled else { return }
            self.duplicateCheckTask = nil
            guard let digest, let existing else {
                self.beginFileTranscription(fileURL: fileURL, translateOverride: translateOverride, sourceDigest: digest)
                return
            }
            switch self.duplicateImportPolicy {
            case .transcribeAgain:
                self.beginFileTranscription(fileURL: fileURL, translateOverride: translateOverride, sourceDigest: digest)
                return
            case .openExisting:
                self.loadEntry(existing.id)
                return
            case .alwaysAsk:
                break
            }
            self.duplicateImport = DuplicateImport(
                entryID: existing.id,
                entryTitle: LibraryEntryDisplay.title(for: existing),
                modelName: existing.modelName,
                createdAt: existing.createdAt,
                durationSeconds: existing.durationSeconds,
                fileURL: fileURL,
                digest: digest,
                translateOverride: translateOverride
            )
        }
    }

    /// Waits for the pending hash-and-look-up so a caller can assert on what it decided.
    func awaitDuplicateCheck() async {
        while let task = duplicateCheckTask {
            await task.value
            if duplicateCheckTask == task { duplicateCheckTask = nil }
        }
    }

    func openExistingDuplicate(remembering remember: Bool) {
        guard let pending = duplicateImport else { return }
        if remember { duplicateImportPolicy = .openExisting }
        duplicateImport = nil
        loadEntry(pending.entryID)
    }

    func transcribeDuplicateAgain(remembering remember: Bool) {
        guard let pending = duplicateImport else { return }
        if remember { duplicateImportPolicy = .transcribeAgain }
        duplicateImport = nil
        beginFileTranscription(
            fileURL: pending.fileURL,
            translateOverride: pending.translateOverride,
            sourceDigest: pending.digest
        )
    }

    /// Dismissing without choosing leaves the file alone: the sheet interrupted the import, and
    /// starting it anyway would make the Escape key mean Transcribe Again.
    func dismissDuplicateImport() {
        duplicateImport = nil
    }

    /// Batch imports never prompt. Unless the policy is Transcribe it again, files the library
    /// already holds are dropped and counted, and the batch page says how many.
    func importBatchFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        batchDuplicatesSkipped = 0
        // Chained, not concurrent: two drops racing would interleave their jobs and leave the
        // notice reading whichever hash finished last.
        let previous = batchImportTask
        let deadline = fileReadDeadline
        let skipsDuplicates = duplicateImportPolicy.batchSkipsDuplicates
        batchImportTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var keep: [URL] = []
            var skipped = 0
            for url in urls {
                guard skipsDuplicates,
                      let digest = await SourceDigest.digest(of: url, deadline: deadline),
                      await self.library.findEntry(digest: digest) != nil
                else {
                    keep.append(url)
                    continue
                }
                skipped += 1
            }
            guard !Task.isCancelled else { return }
            self.batchDuplicatesSkipped = skipped
            if keep.isEmpty {
                if skipped > 0, self.features.isEnabled(.batch) { self.route = .batch }
                return
            }
            self.addBatchFiles(keep)
        }
    }

    /// Waits for the duplicate filter to hand its survivors to the batch. The hashing is async;
    /// tests and the bridge need the seam.
    func awaitBatchImport() async {
        while let task = batchImportTask {
            await task.value
            if batchImportTask == task { batchImportTask = nil }
        }
    }

    var batchDuplicateNotice: String? {
        switch batchDuplicatesSkipped {
        case ..<1: return nil
        case 1: return String(localized: "1 already in your library")
        default: return String(localized: "\(batchDuplicatesSkipped) already in your library")
        }
    }
}
