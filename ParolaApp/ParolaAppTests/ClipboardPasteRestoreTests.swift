import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("Clipboard paste restore")
struct ClipboardPasteRestoreTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("paste-restore-test-\(UUID())"))
    }

    private func inserter(on pasteboard: NSPasteboard, posts: PostCounter) -> ClipboardPasteInserter {
        ClipboardPasteInserter(
            trustCheck: { true },
            pasteboardName: pasteboard.name,
            restoreDelay: .milliseconds(150),
            postPaste: { posts.count += 1 }
        )
    }

    @MainActor
    final class PostCounter { var count = 0 }

    @Test("a paste puts the earlier clipboard back")
    func restoresAfterOnePaste() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("user clip", forType: .string)
        let posts = PostCounter()
        try await inserter(on: pasteboard, posts: posts).insert("first")
        #expect(pasteboard.string(forType: .string) == "first")
        await waitUntil { pasteboard.string(forType: .string) == "user clip" }
        #expect(posts.count == 1)
    }

    @Test("a second paste inside the restore window still restores the user's clipboard, not the first dictation")
    func backToBackPastesKeepTheOriginal() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("user clip", forType: .string)
        let posts = PostCounter()
        let inserter = inserter(on: pasteboard, posts: posts)
        try await inserter.insert("first")
        try await inserter.insert("second")
        #expect(pasteboard.string(forType: .string) == "second")
        await waitUntil { pasteboard.string(forType: .string) == "user clip" }
        #expect(posts.count == 2)
    }

    @Test("a clipboard the user changed after the paste is left alone")
    func changedClipboardIsKept() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("user clip", forType: .string)
        let posts = PostCounter()
        let inserter = inserter(on: pasteboard, posts: posts)
        try await inserter.insert("first")
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        try await inserter.insert("second")
        await settle(for: .milliseconds(400))
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }
}
