import Foundation
import ParolaCore

/// A dismissible strip over whatever page is open: an export's count, a failed library mutation, or a failure from another page.
struct ExportNotice: Equatable, Identifiable {
    enum Tone: Equatable {
        case success, info, failure
    }

    struct Failure: Equatable {
        let name: String
        let reason: String
    }

    struct Action: Equatable, Identifiable {
        enum Handler: Equatable {
            case openEntry(LibraryEntry.ID)
            case transcribeEntry(LibraryEntry.ID)
        }

        let id = UUID()
        let title: String
        let handler: Handler
    }

    let id = UUID()
    let message: String
    let failures: [Failure]
    /// Where a bulk export wrote, for Reveal.
    let folder: URL?
    let tone: Tone
    var offersFolderChoice = false
    var actions: [Action] = []

    var succeeded: Bool { tone == .success }
    /// A notice with actions waits to be dismissed or acted on, whatever its tone.
    var autoDismisses: Bool { tone != .failure && actions.isEmpty }

    static func failed(_ error: Error) -> ExportNotice {
        ExportNotice(message: AppModel.exportFailureMessage(for: error), failures: [], folder: nil, tone: .failure)
    }

    static var autoExportFolderMissing: ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export skipped this transcript: recordings and links save to an auto-export folder, and none is chosen yet. Choose one in Settings › Auto-Export."),
            failures: [], folder: nil, tone: .failure, offersFolderChoice: true
        )
    }

    static var autoExportFolderUnavailable: ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export can't reach its folder. Choose it again in Settings › Auto-Export."),
            failures: [], folder: nil, tone: .failure, offersFolderChoice: true
        )
    }

    static func autoExportFailed(_ error: Error) -> ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export couldn't write to its folder: \(error.localizedDescription)"),
            failures: [], folder: nil, tone: .failure, offersFolderChoice: true
        )
    }

    static func bulk(exported: Int, of total: Int, failures: [Failure], folder: URL) -> ExportNotice {
        ExportNotice(
            message: String(localized: "Exported \(exported) of \(total)"),
            failures: failures,
            folder: folder,
            tone: failures.isEmpty ? .success : .failure
        )
    }
}

/// The folder a take's or a link's auto-exports go to: a bookmark, so a moved folder is still found.
struct AutoExportFolder: Codable, Equatable, Sendable {
    var bookmark: Data
    var path: String
}
