import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("parola_transcribe arguments")
struct TranscribeRequestTests {

    // MARK: - Schema

    @Test("the transcribe schema advertises translate, initial_prompt, output_path and save")
    func schemaCarriesTheNewArguments() throws {
        let props = try transcribeProperties()

        let translate = try #require(props["translate"] as? [String: Any])
        #expect(translate["type"] as? String == "boolean")
        #expect(translate["default"] as? Bool == false)

        let prompt = try #require(props["initial_prompt"] as? [String: Any])
        #expect(prompt["type"] as? String == "string")
        #expect((prompt["description"] as? String)?.contains("224") == true)

        let outputPath = try #require(props["output_path"] as? [String: Any])
        #expect(outputPath["type"] as? String == "string")

        let save = try #require(props["save"] as? [String: Any])
        #expect(save["type"] as? String == "boolean")
        #expect(save["default"] as? Bool == false)
    }

    @Test("the format enum matches the formats the tool can render")
    func schemaFormatEnumMatchesRenderer() throws {
        let format = try #require(try transcribeProperties()["format"] as? [String: Any])
        #expect(format["enum"] as? [String] == TranscribeFormat.allCases.map(\.rawValue))
    }

    // MARK: - Parsing

    @Test("translate and initial_prompt reach the transcription options")
    func translateAndPromptMapIntoOptions() throws {
        let request = try TranscribeRequest(args: [
            "path": "/tmp/talk.wav",
            "translate": true,
            "initial_prompt": "Parola, WhisperKit, Stefano",
            "format": "SRT",
        ])
        #expect(request.options.task == .translate)
        #expect(request.options.initialPrompt == "Parola, WhisperKit, Stefano")
        #expect(request.format == .srt)
        #expect(request.sourceURL.path == "/tmp/talk.wav")
    }

    @Test("the defaults transcribe verbatim, write no file and save nothing")
    func defaultsLeaveEverythingOff() throws {
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav"])
        #expect(request.options.task == .transcribe)
        #expect(request.options.initialPrompt == nil)
        #expect(request.format == .txt)
        #expect(request.outputURL == nil)
        #expect(request.save == false)
    }

    @Test("a blank initial_prompt is dropped instead of biasing the decoder with nothing")
    func blankPromptIsDropped() throws {
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav", "initial_prompt": "   "])
        #expect(request.options.initialPrompt == nil)
    }

    @Test("a missing path is refused by name")
    func missingPathRefused() {
        #expect(throws: MCPToolError.self) { try TranscribeRequest(args: [:]) }
    }

    @Test("an unknown format is refused and lists the ones that work")
    func unknownFormatRefused() throws {
        let error = try #require(throws: MCPToolError.self) {
            try TranscribeRequest(args: ["path": "/tmp/talk.wav", "format": "docx"])
        }
        #expect(error.message.contains("docx"))
        #expect(error.message.contains("srt"))
    }

    // MARK: - output_path

    @Test("a relative output_path is refused")
    func relativeOutputPathRefused() throws {
        let error = try #require(throws: MCPToolError.self) {
            try TranscribeRequest(args: ["path": "/tmp/talk.wav", "output_path": "out/talk.srt"])
        }
        #expect(error.message.contains("absolute"))
    }

    @Test("output_path creates the missing parents and writes the rendered text")
    func outputPathWritesThroughMissingParents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "nested/deeper/talk.srt")

        let request = try TranscribeRequest(args: [
            "path": "/tmp/talk.wav",
            "format": "srt",
            "output_path": target.path,
        ])
        let rendered = try TranscribeFormat.srt.render(fixture())
        let written = try #require(try request.writeOutput(rendered))

        #expect(written == target)
        #expect(try String(contentsOf: target, encoding: .utf8) == rendered)
        #expect(rendered.contains("00:00:00,000 --> "))
    }

    @Test("a call without output_path writes no file")
    func noOutputPathWritesNothing() throws {
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav"])
        #expect(try request.writeOutput("anything") == nil)
    }

    @Test("an output_path that no file can land on is refused before any audio is touched")
    func unwritableOutputPathRefusedUpFront() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "already-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let onADirectory = try #require(throws: MCPToolError.self) {
            try TranscribeRequest(args: ["path": "/tmp/talk.wav", "output_path": directory.path])
        }
        #expect(onADirectory.message.contains("directory"))

        let readOnly = try #require(throws: MCPToolError.self) {
            try TranscribeRequest(args: ["path": "/tmp/talk.wav", "output_path": "/talk.srt"])
        }
        #expect(readOnly.message.contains("not writable"))
    }

    @Test("a write that fails anyway still returns the transcript, with the failure alongside")
    func failedWriteKeepsTheTranscript() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "out.txt")
        let request = try TranscribeRequest(args: ["path": "/tmp/talk.wav", "output_path": target.path])
        // A directory in the file's place, the shape of a path that goes unwritable after the check.
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let server = MCPServer(libraryStore: temporaryLibrary(in: root), bridge: NullBridge())

        let transcript = fixture()
        let blocks = await server.outputBlocks(for: transcript, rendered: transcript.text, request: request)

        #expect(blocks.first == transcript.text)
        #expect(blocks.count == 2)
        #expect(blocks.last?.contains(target.path) == true)
    }

    // MARK: - Nothing said

    @Test("a transcript with nothing in it says so instead of trailing an empty preview")
    func emptyTranscriptIsReportedAsSuch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = Transcript(segments: [], language: "en", modelName: "tiny", durationSeconds: 0)
        let server = MCPServer(libraryStore: temporaryLibrary(in: root), bridge: NullBridge())

        let plain = try TranscribeRequest(args: ["path": "/tmp/talk.wav"])
        let plainBlocks = await server.outputBlocks(for: empty, rendered: "", request: plain)
        #expect(plainBlocks == [TranscribeReport.noSpeechNote])

        let target = root.appending(path: "out.srt")
        let written = try TranscribeRequest(args: [
            "path": "/tmp/talk.wav",
            "format": "srt",
            "output_path": target.path,
        ])
        let writtenBlocks = await server.outputBlocks(for: empty, rendered: "", request: written)
        let report = try #require(writtenBlocks.first)
        #expect(report.contains(TranscribeReport.noSpeechNote))
        #expect(!report.contains("Preview:"))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Report

    @Test("the report names the file, counts the segments and truncates the preview")
    func reportSummarisesTheWrittenFile() {
        let transcript = Transcript(
            segments: (0..<3).map {
                TranscriptSegment(id: $0, start: Double($0) * 30, end: Double($0) * 30 + 30, text: String(repeating: "ciao ", count: 200))
            },
            language: "it",
            modelName: "tiny",
            durationSeconds: 90
        )
        let rendered = transcript.text
        let report = TranscribeReport.text(
            for: transcript,
            rendered: rendered,
            format: .txt,
            outputURL: URL(fileURLWithPath: "/tmp/out/talk.txt")
        )

        #expect(report.contains("/tmp/out/talk.txt"))
        #expect(report.contains("3 segments"))
        #expect(report.contains("00:01:30"))
        #expect(report.hasSuffix("…"))
        #expect(report.count < rendered.count)
    }

    @Test("a transcript shorter than the preview limit is reported whole")
    func shortPreviewIsNotTruncated() {
        #expect(TranscribeReport.preview(of: "buongiorno") == "buongiorno")
        #expect(TranscribeReport.preview(of: String(repeating: "a", count: 501)).hasSuffix("…"))
    }

    // MARK: - save

    @Test("save adds the transcript to the injected library, titled after the source file")
    func saveAddsToTheInjectedLibrary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appending(path: "sprint review.m4a")
        try Data("fake audio".utf8).write(to: audio)
        let store = LibraryStore(libraryURL: root.appending(path: "Library"), extraIndexer: nil)
        let server = MCPServer(libraryStore: store, bridge: NullBridge())

        let note = await server.saveNote(for: fixture(), sourceURL: audio)

        let entries = await store.list()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(note.contains(entry.id))
        #expect(entry.title == "sprint review")

        let matches = await store.search("sprint")
        #expect(matches.contains { $0.entryID == entry.id })
    }

    @Test("a saved entry is searchable from a fresh store, not just this one's memory")
    func saveFlushesTheSearchIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library")
        let audio = root.appending(path: "talk.m4a")
        try Data("fake audio".utf8).write(to: audio)
        let server = MCPServer(
            libraryStore: LibraryStore(libraryURL: library, extraIndexer: nil),
            bridge: NullBridge()
        )

        let note = await server.saveNote(for: fixture(), sourceURL: audio)
        #expect(!note.contains("failed"))

        // The debounced index save has not fired yet; a process that exits now must not lose it.
        let reopened = LibraryStore(libraryURL: library, extraIndexer: nil)
        #expect(await !reopened.search("sprint").isEmpty)
    }

    @Test("a library that can't be written is reported, not thrown")
    func failedSaveIsReported() async throws {
        let store = LibraryStore(libraryURL: URL(fileURLWithPath: "/dev/null/parola"), extraIndexer: nil)
        let server = MCPServer(libraryStore: store, bridge: NullBridge())

        let note = await server.saveNote(for: fixture(), sourceURL: URL(fileURLWithPath: "/tmp/missing.wav"))

        #expect(note.contains("failed"))
        #expect(await store.list().isEmpty)
    }

    // MARK: - Helpers

    private func transcribeProperties() throws -> [String: Any] {
        let data = try JSONEncoder().encode(EngineTool.transcribe.mcpTool)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try #require(parsed["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["path"])
        return try #require(schema["properties"] as? [String: Any])
    }

    private func fixture() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "sprint review"),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "shipping on friday"),
            ],
            language: "en",
            modelName: "tiny",
            durationSeconds: 4
        )
    }

    private func temporaryLibrary(in root: URL) -> LibraryStore {
        LibraryStore(libraryURL: root.appending(path: "Library"), extraIndexer: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "parola-mcp-transcribe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String { "{}" }
}
