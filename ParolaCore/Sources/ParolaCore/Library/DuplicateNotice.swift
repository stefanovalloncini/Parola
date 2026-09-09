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
    /// hand the same digest to `LibraryStore.add` rather than reading the file twice.
    public static func lookup(for url: URL, in store: LibraryStore) async -> Lookup {
        guard let digest = await SourceDigest.digest(of: url) else {
            return Lookup(digest: nil, entry: nil)
        }
        return Lookup(digest: digest, entry: await store.findEntry(digest: digest))
    }
}
