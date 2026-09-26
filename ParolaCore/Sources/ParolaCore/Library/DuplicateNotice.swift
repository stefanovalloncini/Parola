import Foundation

/// The line the CLI and the MCP server print when an import is already in the library. One text
/// for both so the two surfaces never drift.
public enum DuplicateNotice {
    public static func text(
        for entry: LibraryEntry,
        skipping: Bool,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let when = entry.createdAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
        let action = skipping ? "skipping" : "transcribing again"
        return "Already in the library as \(entry.title) (\(entry.modelName), \(when)); \(action)"
    }

    /// What one file's digest found in the library. `entry` is nil when the file is new, and
    /// `digest` is nil when it could not be hashed at all.
    public struct Lookup: Sendable {
        public let digest: String?
        public let entry: LibraryEntry?
    }

    /// Hashes the file once and looks it up, so a caller that goes on to save the transcript can
    /// hand the same digest to `LibraryStore.add` rather than reading the file twice. `deadline`
    /// caps the read; nil gives the budget a file that size is allowed.
    public static func lookup(for url: URL, in store: LibraryStore, deadline: Duration? = nil) async -> Lookup {
        guard let digest = await SourceDigest.digest(of: url, deadline: deadline) else {
            return Lookup(digest: nil, entry: nil)
        }
        return Lookup(digest: digest, entry: await store.findEntry(digest: digest))
    }

    /// `lookup` for many files, `width` hashes at a time, answered in the order the files came in.
    public static func lookups(
        for urls: [URL],
        in store: LibraryStore,
        deadline: Duration? = nil,
        width: Int = 3
    ) async -> [Lookup] {
        var found = [Lookup?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, Lookup).self) { group in
            var next = 0
            func startNext() {
                guard next < urls.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await lookup(for: urls[index], in: store, deadline: deadline)) }
            }
            for _ in 0..<max(1, width) { startNext() }
            while let (index, lookup) = await group.next() {
                found[index] = lookup
                startNext()
            }
        }
        return found.map { $0 ?? Lookup(digest: nil, entry: nil) }
    }
}
