import Foundation
import Testing
@testable import Parola

@Suite("Recent files list")
struct RecentFilesListTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).mp3")
    }

    @Test("append moves the entry to the head")
    func appendMovesToHead() {
        var list = RecentFilesList(capacity: 5)
        list.note(url("a"))
        list.note(url("b"))
        list.note(url("c"))
        #expect(list.urls.first == url("c"))
        list.note(url("a"))
        #expect(list.urls.first == url("a"))
    }

    @Test("duplicates are deduped")
    func deduped() {
        var list = RecentFilesList(capacity: 5)
        list.note(url("a"))
        list.note(url("a"))
        list.note(url("a"))
        #expect(list.urls.count == 1)
    }

    @Test("capacity caps the list to the most-recent N")
    func cappedByCapacity() {
        var list = RecentFilesList(capacity: 3)
        for c in ["a", "b", "c", "d", "e"] { list.note(url(c)) }
        #expect(list.urls.map(\.lastPathComponent) == ["e.mp3", "d.mp3", "c.mp3"])
    }

    @Test("forget removes a URL")
    func forget() {
        var list = RecentFilesList(capacity: 5)
        list.note(url("a"))
        list.note(url("b"))
        list.forget(url("a"))
        #expect(list.urls.map(\.lastPathComponent) == ["b.mp3"])
    }

    @Test("clear empties the list")
    func clear() {
        var list = RecentFilesList(capacity: 5)
        list.note(url("a"))
        list.clear()
        #expect(list.urls.isEmpty)
    }

    @Test("encodes and decodes to JSON strings")
    func roundTrip() throws {
        var list = RecentFilesList(capacity: 4)
        list.note(url("a"))
        list.note(url("b"))
        let raw = list.encoded
        var rehydrated = RecentFilesList(capacity: 4)
        rehydrated.decode(raw)
        #expect(rehydrated.urls == list.urls)
    }
}
