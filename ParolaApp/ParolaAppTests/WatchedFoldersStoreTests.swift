import Foundation
import Testing
@testable import Parola

@Suite("WatchedFolder value type")
struct WatchedFoldersStoreTests {

    @Test("displayName is the last path component of the display path")
    func displayName() {
        let folder = WatchedFolder(bookmark: Data(), displayPath: "/Users/me/Movies/Recordings")
        #expect(folder.displayName == "Recordings")
    }

    @Test("displayName drops a trailing slash")
    func displayNameTrailingSlash() {
        let folder = WatchedFolder(bookmark: Data(), displayPath: "/Users/me/Audio/")
        #expect(folder.displayName == "Audio")
    }

    @Test("a folder round-trips through the JSON coders the store uses")
    func roundTrip() throws {
        let original = WatchedFolder(
            bookmark: Data([0x01, 0x02, 0x03, 0xFF]),
            displayPath: "/Volumes/External/Clips"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchedFolder.self, from: data)
        #expect(decoded == original)
        #expect(decoded.id == original.id)
        #expect(decoded.bookmark == original.bookmark)
        #expect(decoded.displayName == "Clips")
    }

    @Test("an array of folders round-trips and preserves order")
    func arrayRoundTrip() throws {
        let folders = [
            WatchedFolder(bookmark: Data([0x10]), displayPath: "/a/First"),
            WatchedFolder(bookmark: Data([0x20]), displayPath: "/b/Second"),
            WatchedFolder(bookmark: Data([0x30]), displayPath: "/c/Third"),
        ]
        let data = try JSONEncoder().encode(folders)
        let decoded = try JSONDecoder().decode([WatchedFolder].self, from: data)
        #expect(decoded == folders)
        #expect(decoded.map(\.displayName) == ["First", "Second", "Third"])
    }

    @Test("each generated folder has a distinct identity")
    func distinctIdentities() {
        let a = WatchedFolder(bookmark: Data(), displayPath: "/same/path")
        let b = WatchedFolder(bookmark: Data(), displayPath: "/same/path")
        #expect(a.id != b.id)
        #expect(a != b)
    }

    @Test("a supplied id is retained for refreshed bookmarks")
    func retainsSuppliedID() {
        let id = UUID()
        let initial = WatchedFolder(id: id, bookmark: Data([0x01]), displayPath: "/x/Folder")
        let refreshed = WatchedFolder(id: id, bookmark: Data([0x02]), displayPath: "/x/Folder")
        #expect(initial.id == refreshed.id)
        #expect(initial != refreshed)
    }
}
