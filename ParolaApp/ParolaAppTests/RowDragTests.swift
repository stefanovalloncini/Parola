import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Parola
import ParolaCore

@MainActor
@Suite("Row drags")
struct RowDragTests {

    private static func makeBundle(in dir: URL, name: String = "20261005T101502-3f2a") throws -> URL {
        try ParolaDocument.write(
            transcript: Transcript(
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 1, text: "Sprint went well."),
                    TranscriptSegment(id: 1, start: 1, end: 2, text: "Ship it."),
                ],
                language: "en",
                modelName: "stub"
            ),
            audioURL: nil,
            to: dir.appendingPathComponent(name)
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RowDragTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dragPasteboard(_ url: URL, marked: Bool) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("RowDragTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if marked { item.setData(Data(), forType: .init(UTType.parolaRowDrag.identifier)) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    @Test("a row dragged over its own window offers nothing to open")
    func ownRowOpensNothing() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try Self.makeBundle(in: dir)

        let fromFinder = Self.dragPasteboard(bundle, marked: false)
        let fromRow = Self.dragPasteboard(bundle, marked: true)
        defer { fromFinder.releaseGlobally(); fromRow.releaseGlobally() }

        let finderPayload = SplitDropDelegate.payload(on: fromFinder)
        let rowPayload = SplitDropDelegate.payload(on: fromRow)

        #expect(finderPayload == .projects(count: 1))
        #expect(rowPayload == nil)
    }

    @Test("library and Queue rows mark their drags as this app's")
    func rowsMarkTheirDrags() {
        let queueProvider = QueueView.dragProvider(for: URL(fileURLWithPath: "/tmp/RowDragTests/done.srt"))
        let queueTypes = queueProvider.registeredContentTypes

        #expect(queueTypes.contains(.parolaRowDrag))
        #expect(LibraryEntryDragItem.exportedContentTypes() == [.parolaDocument, .utf8PlainText, .parolaRowDrag])
    }

    @Test("a row dragged to Finder lands as a copy named by its title")
    func finderGetsATitledCopy() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try Self.makeBundle(in: dir)
        let item = LibraryEntryDragItem(id: "20261005T101502-3f2a", title: "Sprint 18 retro: notes", bundleURL: bundle)

        let copy = try item.writeCopy()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        #expect(copy.lastPathComponent == "Sprint 18 retro- notes.parola")
        #expect(try ParolaDocument.readTranscriptText(at: copy) == "Sprint went well. Ship it.")
        #expect(FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test("a row whose title runs past a file name's limit still lands, under a shorter name")
    func longTitleStillLands() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try Self.makeBundle(in: dir)
        let title = String(repeating: "La riunione è andata così ", count: 16)
        let item = LibraryEntryDragItem(id: "20261005T101502-3f2a", title: title, bundleURL: bundle)

        let copy = try item.writeCopy()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        #expect(copy.lastPathComponent.utf8.count <= 255)
        #expect(copy.lastPathComponent.hasPrefix("La riunione è andata così"))
        #expect(copy.pathExtension == "parola")
    }

    @Test("copies left by earlier drags are swept; a fresh one and anything else stay")
    func staleCopiesAreSwept() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let twoHoursAgo = Date().addingTimeInterval(-7_200)
        let stale = dir.appendingPathComponent("ParolaDrag-old")
        let fresh = dir.appendingPathComponent("ParolaDrag-new")
        let other = dir.appendingPathComponent("Other-old")
        for folder in [stale, fresh, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for folder in [stale, other] {
            try FileManager.default.setAttributes([.creationDate: twoHoursAgo], ofItemAtPath: folder.path)
        }

        LibraryEntryDragItem.sweepStaleCopies(in: dir)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("a row dropped on a text target gives the transcript")
    func textTargetsGetTheTranscript() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try Self.makeBundle(in: dir)
        let item = LibraryEntryDragItem(id: "20261005T101502-3f2a", title: "Sprint 18 retro", bundleURL: bundle)

        let data = try await item.exported(as: .utf8PlainText)

        #expect(String(decoding: data, as: UTF8.self) == "Sprint went well. Ship it.")
    }
}
