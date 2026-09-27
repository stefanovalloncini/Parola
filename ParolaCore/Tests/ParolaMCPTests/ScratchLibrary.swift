import Foundation
import ParolaCore

/// A throwaway library for a test server, read the way the server reads the real one. Never
/// `LibraryStore.shared`: that is the user's real library.
func scratchLibraryStore() -> LibraryStore {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-mcp-scratch-\(UUID().uuidString)", isDirectory: true)
    return LibraryStore(libraryURL: tmp, extraIndexer: nil, role: .reader)
}
