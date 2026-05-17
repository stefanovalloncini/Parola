import Foundation
import Testing
@testable import ParolaCore

@Suite("FolderWatcher media filter", .tags(.fileSystem))
struct FolderWatcherTests {
    @Test("audio extensions are recognized")
    func audio() {
        for ext in ["mp3", "wav", "m4a", "flac"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(FolderWatcher.isMediaFile(url))
        }
    }

    @Test("video extensions are recognized")
    func video() {
        for ext in ["mp4", "mov", "m4v"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(FolderWatcher.isMediaFile(url))
        }
    }

    @Test("non-media extensions are rejected")
    func nonMedia() {
        for ext in ["txt", "pdf", "jpg", "swift"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(!FolderWatcher.isMediaFile(url))
        }
    }

    @Test("extension match is case-insensitive")
    func caseInsensitive() {
        #expect(FolderWatcher.isMediaFile(URL(fileURLWithPath: "/tmp/x.MP3")))
        #expect(FolderWatcher.isMediaFile(URL(fileURLWithPath: "/tmp/x.Mov")))
    }
}
