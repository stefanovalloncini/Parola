import Foundation
import ParolaCore

/// A throwaway library for a test server. Never `LibraryStore.shared`: that is the user's real
/// library, and the store's init walks and can rewrite it.
func scratchLibraryStore() -> LibraryStore {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-mcp-scratch-\(UUID().uuidString)", isDirectory: true)
    return LibraryStore(libraryURL: tmp, extraIndexer: nil)
}
