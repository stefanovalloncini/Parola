import CryptoKit
import Foundation
import ParolaCore

extension AppModel {

    /// A take's audio goes to the Auto-Export folder in the format it was stored in; a file the user imported is theirs already.
    func exportRecording(of entry: LibraryEntry, source: EntrySource) -> Task<Void, Never>? {
        guard autoExportRecording, source == .microphone || source == .systemAudio, let folder = autoExportFolder else {
            return nil
        }
        let title = LibraryEntryDisplay.title(for: entry)
        let entryID = entry.id
        return Task { [weak self, library] in
            guard let loaded = try? await library.load(entryID), let audio = loaded.document.audioURL else { return }
            guard case .resolved(let url, _) = await Self.resolve(folder) else {
                self?.noteAutoExport(.autoExportFolderUnavailable)
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Self.copyOwned(audio, into: url, named: title, tail: "", owner: "\(entryID).recording")
            } catch {
                ParolaLog.error(.export, "the recording could not be exported", [.error: .error(error)])
                self?.noteAutoExport(.autoExportFailed(error))
            }
        }
    }

    func queueSummaryExport(_ summary: Summary, of entryID: LibraryEntry.ID) {
        let earlier = summaryExports
        summaryExports = Task { [weak self] in
            await earlier?.value
            await self?.exportSummary(summary, of: entryID)?.value
        }
    }

    func awaitSummaryExports() async {
        await summaryExports?.value
    }

    /// Runs whenever a summary lands, so a late one gets its file and a regenerated one replaces it.
    func exportSummary(_ summary: Summary, of entryID: LibraryEntry.ID) -> Task<Void, Never>? {
        guard autoExportSummary, let folder = autoExportFolder else { return nil }
        let text = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Task { [weak self, library] in
            guard let loaded = try? await library.load(entryID) else { return }
            guard case .resolved(let url, _) = await Self.resolve(folder) else {
                self?.noteAutoExport(.autoExportFolderUnavailable)
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Self.writeSummaryFile(
                    Data((text + "\n").utf8), into: url, named: LibraryEntryDisplay.title(for: loaded.entry), entryID: entryID
                )
            } catch {
                ParolaLog.error(.export, "the summary could not be exported", [.error: .error(error)])
                self?.noteAutoExport(.autoExportFailed(error))
            }
        }
    }

    /// The file name an entry's title makes: the sidecar naming, so a slash or a leading dot can't escape the folder.
    nonisolated static func exportFileBaseName(_ title: String) -> String {
        SidecarSource(fileExtension: "", folder: URL(fileURLWithPath: "/"), baseName: title, owner: "").baseName
    }

    /// The first `name (n).ext` that is free or was written by `owner`; a file anyone else wrote stays as it is.
    nonisolated static func ownedTarget(in folder: URL, base: String, tail: String, fileExtension: String, owner: String) -> URL {
        let manager = FileManager.default
        for number in 1...1000 {
            let stem = number == 1 ? base : "\(base) (\(number))"
            let url = folder.appendingPathComponent(stem + tail).appendingPathExtension(fileExtension)
            if !manager.fileExists(atPath: url.path) || OutputMarker.owner(of: url) == owner { return url }
        }
        return folder.appendingPathComponent(base + tail + "-" + UUID().uuidString.prefix(8)).appendingPathExtension(fileExtension)
    }

    @concurrent
    nonisolated static func copyOwned(_ source: URL, into folder: URL, named title: String, tail: String, owner: String) async throws {
        let target = ownedTarget(
            in: folder, base: exportFileBaseName(title), tail: tail, fileExtension: source.pathExtension, owner: owner
        )
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try manager.copyItem(at: source, to: staging)
            OutputMarker.mark(staging, owner: owner)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: staging, to: target)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    nonisolated static func summaryOwnerPrefix(_ entryID: String) -> String { "\(entryID).summary:" }

    /// The mark carries the hash of what was written, so a file the user edited since is theirs and stays.
    @concurrent
    nonisolated static func writeSummaryFile(_ data: Data, into folder: URL, named title: String, entryID: String) async throws {
        let manager = FileManager.default
        let prefix = summaryOwnerPrefix(entryID)
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            guard let owner = OutputMarker.owner(of: url), owner.hasPrefix(prefix),
                  let current = try? Data(contentsOf: url), contentHash(current) == String(owner.dropFirst(prefix.count))
            else { continue }
            try manager.removeItem(at: url)
        }
        let base = exportFileBaseName(title)
        var target = folder.appendingPathComponent(base + " – Summary").appendingPathExtension("md")
        var number = 2
        while manager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(number)) – Summary").appendingPathExtension("md")
            number += 1
        }
        try data.write(to: target, options: .atomic)
        OutputMarker.mark(target, owner: prefix + contentHash(data))
    }

    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
