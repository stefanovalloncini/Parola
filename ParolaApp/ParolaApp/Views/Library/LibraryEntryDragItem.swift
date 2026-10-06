import AppKit
import CoreTransferable
import Foundation
import ParolaCore
import UniformTypeIdentifiers

extension UTType {
    static let parolaDocument = UTType(exportedAs: "app.parola.document")
    /// Rows the window lists put it on their drags, so the window never offers to open its own rows.
    static let parolaRowDrag = UTType(exportedAs: "app.parola.row-drag")
}

enum RowDrag {
    static func isFromThisApp(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(NSPasteboard.PasteboardType(UTType.parolaRowDrag.identifier)) ?? false
    }

    static func mark(_ provider: NSItemProvider) {
        provider.registerDataRepresentation(for: .parolaRowDrag) { load in
            load(Data(), nil)
            return nil
        }
    }
}

/// A library row dragged out of the window: a copy of its document under its title, or its text for a text target.
struct LibraryEntryDragItem: Transferable, Identifiable {
    let id: LibraryEntry.ID
    let title: String
    let bundleURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .parolaDocument) { item in
            SentTransferredFile(try item.writeCopy(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.fileName }
        DataRepresentation(exportedContentType: .utf8PlainText) { item in
            Data(try ParolaDocument.readTranscriptText(at: item.bundleURL).utf8)
        }
        DataRepresentation(exportedContentType: .parolaRowDrag) { item in Data(item.id.utf8) }
    }

    init(id: LibraryEntry.ID, title: String, bundleURL: URL) {
        self.id = id
        self.title = title
        self.bundleURL = bundleURL
    }

    init(entry: LibraryEntry, showsAITitle: Bool) {
        self.init(
            id: entry.id,
            title: LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showsAITitle),
            bundleURL: entry.bundleURL
        )
    }

    var fileName: String {
        TranscriptShareFile.safeName(for: title) + ".parola"
    }

    func writeCopy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParolaDrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(fileName, isDirectory: true)
        try FileManager.default.copyItem(at: bundleURL, to: copy)
        return copy
    }
}
