import Foundation
import Testing
@testable import Parola

@Suite("DroppedFiles classifier")
struct DroppedFilesTests {

    private static func makeScratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppedFilesTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func touch(_ path: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        return url
    }

    @Test("every watched-folder media extension classifies as media, including mkv")
    func mediaExtensionsMatchFolderWatcher() {
        for ext in ["mp3", "wav", "m4a", "flac", "opus", "mp4", "mov", "mkv", "webm", "avi"] {
            let url = URL(fileURLWithPath: "/tmp/clip.\(ext)")
            let files = DroppedFiles.classify([url])
            #expect(files.media == [url], "\(ext) should classify as media")
        }
    }

    @Test("subtitles, projects and unsupported files land in their own buckets")
    func splitsByRole() {
        let srt = URL(fileURLWithPath: "/tmp/a.srt")
        let vtt = URL(fileURLWithPath: "/tmp/a.vtt")
        let project = URL(fileURLWithPath: "/tmp/a.parola")
        let pdf = URL(fileURLWithPath: "/tmp/a.pdf")

        let files = DroppedFiles.classify([srt, vtt, project, pdf])

        #expect(files.subtitles == [srt, vtt])
        #expect(files.projects == [project])
        #expect(files.media.isEmpty)
    }

    @Test("a PDF alone is unsupported")
    func unsupportedAlone() {
        let files = DroppedFiles.classify([URL(fileURLWithPath: "/tmp/a.pdf")])
        #expect(files.isEmpty)
        #expect(files.kind == .unsupported)
    }

    @Test("a yt-dlp host becomes a link and any other web address is dropped")
    func classifiesLinks() {
        let youtube = URL(string: "https://www.youtube.com/watch?v=abc")!
        let blog = URL(string: "https://example.com/post")!

        let files = DroppedFiles.classify([youtube, blog])

        #expect(files.links == [youtube])
        #expect(files.kind == .links(count: 1))
    }

    @Test("a folder expands recursively and sorts by path")
    func expandsFoldersRecursively() throws {
        let dir = try Self.makeScratch("recursive")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("b.wav", in: dir)
        try Self.touch("nested/deep/c.mkv", in: dir)
        try Self.touch("nested/notes.pdf", in: dir)
        try Self.touch("a.srt", in: dir)

        let files = DroppedFiles.classify([dir])

        #expect(files.media.map(\.lastPathComponent) == ["b.wav", "c.mkv"])
        #expect(files.subtitles.map(\.lastPathComponent) == ["a.srt"])
    }

    @Test("a shallow classification stops at the first level")
    func shallowStaysAtTopLevel() throws {
        let dir = try Self.makeScratch("shallow")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("top.wav", in: dir)
        try Self.touch("nested/deep.wav", in: dir)

        let files = DroppedFiles.classify([dir], folders: .shallow)

        #expect(files.media.map(\.lastPathComponent) == ["top.wav"])
    }

    @Test("a project package inside a folder is kept whole, not walked into")
    func projectPackagesAreNotWalked() throws {
        let dir = try Self.makeScratch("packages")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("session.parola/audio.wav", in: dir)
        try Self.touch("loose.wav", in: dir)

        let files = DroppedFiles.classify([dir])

        #expect(files.projects.map(\.lastPathComponent) == ["session.parola"])
        #expect(files.media.map(\.lastPathComponent) == ["loose.wav"])
    }

    @Test("media inside a package in a dropped folder stays in the package, as a watched folder leaves it")
    func packagesInsideFoldersAreNotWalked() throws {
        let dir = try Self.makeScratch("library-bundles")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("Photos Library.photoslibrary/originals/0/clip.mov", in: dir)
        try Self.touch("Editor.app/Contents/Resources/intro.mp4", in: dir)
        try Self.touch("loose.wav", in: dir)

        let files = DroppedFiles.classify([dir])

        #expect(files.media.map(\.lastPathComponent) == ["loose.wav"])
    }

    @Test("a package dropped on its own is not opened")
    func droppedPackageIsOpaque() throws {
        let dir = try Self.makeScratch("lone-bundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("Photos Library.photoslibrary/originals/0/clip.mov", in: dir)

        let files = DroppedFiles.classify([dir.appendingPathComponent("Photos Library.photoslibrary")])

        #expect(files.isEmpty)
    }

    @Test("the off-main walk finds what the walk on the caller's thread finds, in the same order")
    func offMainWalkMatches() async throws {
        let dir = try Self.makeScratch("off-main")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.touch("b.wav", in: dir)
        try Self.touch("nested/a.mkv", in: dir)
        try Self.touch("notes.srt", in: dir)
        try Self.touch("take.parola/audio.wav", in: dir)

        let offMain = await DroppedFiles.classifyOffMain([dir])

        #expect(offMain == DroppedFiles.classify([dir]))
        #expect(offMain.all.map(\.lastPathComponent) == ["b.wav", "a.mkv", "notes.srt", "take.parola"])
    }

    @Test("the same file dropped twice is kept once")
    func deduplicates() {
        let url = URL(fileURLWithPath: "/tmp/one.wav")
        let files = DroppedFiles.classify([url, URL(fileURLWithPath: "/tmp/./one.wav")])
        #expect(files.media.count == 1)
    }

    @Test("media alongside subtitles reads as mixed")
    func mixedKind() {
        let files = DroppedFiles.classify([
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/a.srt"),
        ])
        #expect(files.kind == .mixed(count: 2))
    }

    @Test("media on its own reads as media with a count")
    func mediaKind() {
        let files = DroppedFiles.classify([
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/b.wav"),
        ])
        #expect(files.kind == .media(count: 2))
    }
}

@Suite("DroppedFiles zone plan")
struct DroppedFilesPlanTests {

    private func plan(
        _ kind: DroppedFiles.Kind,
        batch: Bool = true,
        youtube: Bool = true,
        deferred: Bool = false
    ) -> DroppedFiles.ZonePlan {
        DroppedFiles.plan(for: kind, batchEnabled: batch, youtubeEnabled: youtube, arrivalsDeferred: deferred)
    }

    @Test("a single media file still offers both halves")
    func singleFileSplits() {
        #expect(plan(.media(count: 1)) == .split(count: 1))
    }

    @Test("a gated batch build collapses to one transcribe zone")
    func batchDisabledCollapses() {
        #expect(plan(.media(count: 3), batch: false) == .transcribeOnly(count: 3))
    }

    @Test("while arrivals are deferred only the queue zone is honest")
    func deferredArrivalsQueueOnly() {
        #expect(plan(.media(count: 2), deferred: true) == .queueOnly(count: 2))
    }

    @Test("subtitles and projects get their own single zone")
    func importZones() {
        #expect(plan(.subtitles(count: 2)) == .importSubtitles(count: 2))
        #expect(plan(.projects(count: 1)) == .openProjects(count: 1))
    }

    @Test("a link zone appears only when the YouTube feature is on")
    func linkNeedsFeature() {
        #expect(plan(.links(count: 1)) == .transcribeLink)
        #expect(plan(.links(count: 1), youtube: false) == .none)
    }

    @Test("an unsupported payload shows nothing")
    func unsupportedShowsNothing() {
        #expect(plan(.unsupported) == .none)
    }

    @Test("a mixed payload behaves like media")
    func mixedSplits() {
        #expect(plan(.mixed(count: 4)) == .split(count: 4))
    }
}
