import Foundation
import Testing
@testable import ParolaCore

@Suite("Obsidian note goldens", .tags(.fileSystem))
struct ObsidianNoteRendererTests {

    static func payload() -> DeliveryPayload {
        DeliveryPayload(
            entryID: "entry-1",
            title: "Interview",
            aiTitle: "Release chat",
            shortSummary: "Two people talk about a release.",
            createdAt: Date(timeIntervalSince1970: 1_780_272_000),
            duration: 134,
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/parola-delivery/interview.m4a"),
            speakers: ["Ada", "Grace"],
            labels: ["work", "product notes"],
            category: .meeting,
            transcript: Transcript(
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 3.5, text: "Welcome back to the show.", speaker: "Ada"),
                    TranscriptSegment(
                        id: 1, start: 3.5, end: 9.125,
                        text: "Glad to be here — we shipped the \"export\" rewrite & it works.",
                        speaker: "Grace"
                    ),
                    TranscriptSegment(id: 2, start: 74, end: 134, text: "Tell me how it went.", speaker: "Ada"),
                ],
                language: "en",
                modelName: "openai_whisper-tiny",
                sourceURL: URL(fileURLWithPath: "/tmp/parola-delivery/interview.m4a"),
                durationSeconds: 134
            ),
            summary: Summary(
                text: "Ada and Grace go over the export rewrite and what shipped.",
                chapters: [Chapter(title: "Welcome", start: 0), Chapter(title: "The rewrite", start: 74)],
                actionItems: ["Write the release note", "Ping the beta list"]
            ),
            favorites: [1, 2],
            markdown: "# Interview\n"
        )
    }

    /// Set PAROLA_REGENERATE_OBSIDIAN_GOLDEN=1 to rewrite Tests/Resources/obsidian-golden/.
    /// Read the diff before committing: these files pin the bytes a note is written with.
    private func compare(_ name: String, options: ObsidianNoteOptions, title: String = "Interview") throws {
        let actual = ObsidianNoteRenderer.render(Self.payload(), options: options, title: title)
        let filename = "\(name).md"

        if ProcessInfo.processInfo.environment["PAROLA_REGENERATE_OBSIDIAN_GOLDEN"] != nil {
            let dir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/obsidian-golden", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: dir.appendingPathComponent(filename))
            Issue.record("Regenerated \(filename). Re-run without PAROLA_REGENERATE_OBSIDIAN_GOLDEN.")
            return
        }

        let url = try #require(
            Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "obsidian-golden"),
            "missing golden: \(filename). Re-run with PAROLA_REGENERATE_OBSIDIAN_GOLDEN=1 to create it."
        )
        let expected = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(actual == expected, "\(filename): the rendered note diverged from its golden file.")
    }

    @Test("the full note reproduces its golden")
    func fullNote() throws {
        var body = ObsidianBodyOptions()
        body.timestamps = true
        try compare("full", options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: body, wikilinks: false))
    }

    @Test("a note without timestamps reproduces its golden")
    func withoutTimestamps() throws {
        try compare(
            "no-timestamps",
            options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: ObsidianBodyOptions(), wikilinks: false)
        )
    }

    @Test("speakers render as wikilinks when that is switched on")
    func wikilinks() throws {
        try compare(
            "wikilinks",
            options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: ObsidianBodyOptions(), wikilinks: true)
        )
    }

    @Test("a favorites-only note reproduces its golden")
    func favoritesOnly() throws {
        var body = ObsidianBodyOptions()
        body.summary = false
        body.transcript = false
        try compare(
            "favorites",
            options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: body, wikilinks: false)
        )
    }

    @Test("a frontmatter subset writes only the keys it names")
    func frontmatterSubset() throws {
        var frontmatter = ObsidianFrontmatterOptions()
        frontmatter.duration = false
        frontmatter.source = false
        frontmatter.language = false
        frontmatter.model = false
        frontmatter.speakers = false
        frontmatter.summary = false
        var body = ObsidianBodyOptions()
        body.summary = false
        body.favorites = false
        try compare(
            "frontmatter-subset",
            options: ObsidianNoteOptions(frontmatter: frontmatter, body: body, wikilinks: false)
        )
    }

    @Test("a note ends with exactly one newline and no trailing spaces")
    func noTrailingWhitespace() {
        let note = ObsidianNoteRenderer.render(
            Self.payload(),
            options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: ObsidianBodyOptions(), wikilinks: false),
            title: "Interview"
        )
        #expect(note.hasSuffix("\n"))
        #expect(!note.hasSuffix("\n\n"))
        #expect(!note.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasSuffix(" ") })
    }

    @Test("frontmatter is left out entirely when every key is off")
    func noFrontmatter() {
        var frontmatter = ObsidianFrontmatterOptions()
        for keyPath in [
            \ObsidianFrontmatterOptions.title, \.date, \.duration, \.source,
            \.language, \.model, \.speakers, \.tags, \.summary,
        ] {
            frontmatter[keyPath: keyPath] = false
        }
        let note = ObsidianNoteRenderer.render(
            Self.payload(),
            options: ObsidianNoteOptions(frontmatter: frontmatter, body: ObsidianBodyOptions(), wikilinks: false),
            title: "Interview"
        )
        #expect(note.hasPrefix("# Interview\n"))
    }

    @Test("a duration in minutes and seconds is quoted so YAML keeps it a string")
    func durationIsQuoted() {
        let note = ObsidianNoteRenderer.render(
            Self.payload(),
            options: ObsidianNoteOptions(frontmatter: ObsidianFrontmatterOptions(), body: ObsidianBodyOptions(), wikilinks: false),
            title: "Interview"
        )
        #expect(note.contains("duration: \"02:14\""))
        #expect(note.contains("date: 2026-06-01T00:00:00Z"))
    }
}

@Suite("Obsidian filenames")
struct ObsidianFilenameTests {
    private let utc = TimeZone(identifier: "UTC")!

    /// `{title}` is the entry's own title, so a case that needs another one puts it on the payload.
    private func filename(_ template: String, title: String = "Interview") -> String {
        var payload = ObsidianNoteRendererTests.payload()
        payload.title = title
        return ObsidianNoteRenderer.filename(template: template, payload: payload, timeZone: utc)
    }

    @Test("every token is replaced")
    func tokens() {
        #expect(filename("{title}") == "Interview")
        #expect(filename("{date} {title}") == "2026-06-01 Interview")
        #expect(filename("{date} {time} {category} — {title}") == "2026-06-01 00-00 meeting — Interview")
    }

    @Test("a token that is not a token is left alone")
    func unknownToken() {
        #expect(filename("{title} {nope}") == "Interview {nope}")
    }

    @Test("characters the filesystem refuses become dashes")
    func sanitising() {
        #expect(filename("{title}", title: #"a/b\c:d*e?f"g<h>i|j"#) == "a-b-c-d-e-f-g-h-i-j")
        #expect(filename("{title}", title: "  padded  ") == "padded")
        #expect(filename("{title}", title: "two\nlines") == "two lines")
    }

    @Test("a name is capped at 200 characters")
    func lengthCap() {
        let long = String(repeating: "x", count: 400)
        #expect(filename("{title}", title: long).count == 200)
    }

    @Test("the title format never reaches the filename")
    func titleFormatDoesNotNameTheFile() {
        var payload = ObsidianNoteRendererTests.payload()
        payload.aiTitle = "Release chat"
        let name = ObsidianNoteRenderer.filename(template: "{title}", payload: payload, timeZone: utc)
        #expect(name == "Interview")
        #expect(TitleFormat.aiTitle.title(for: payload) == "Release chat")
    }

    @Test("a name that sanitises away falls back to a readable one")
    func emptyFallback() {
        #expect(filename("{title}", title: "   ") == "Untitled")
        #expect(filename("", title: "Interview") == "Interview")
        #expect(filename("{title}", title: "...") == "Untitled")
    }

    @Test("a leading dot is dropped so the note is not hidden")
    func leadingDot() {
        #expect(filename("{title}", title: ".secret") == "secret")
    }
}
