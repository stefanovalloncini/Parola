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
            /// A failed take's Retry, for that take only.
            case retryTake(Int)
            /// Back to a failed take's Stage.
            case showTake(Int)
            /// Retry for a failed take a newer take has replaced on the Stage: it runs again from what the failure saved.
            case retrySavedTake(RecordingSession.Failure)
            /// Opens what a failed take saved, once a newer take has replaced it on the Stage.
            case showSavedTake(RecordingSession.Failure)
            case openRecentlyDeleted
            /// Reveals a file in the Finder, as a microphone track Parola keeps.
            case revealFile(URL)
            /// Runs again a file or link run that failed after the user moved on.
            case retryRun(AppModel.RunRetry)

            var takeID: Int? {
                switch self {
                case .retryTake(let id), .showTake(let id): id
                case .openEntry, .transcribeEntry, .retrySavedTake, .showSavedTake, .openRecentlyDeleted, .revealFile, .retryRun: nil
                }
            }
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
    /// The take a notice is about when it has no button for it.
    var forTake: Int?
    /// Only true while a take records, so it goes when the take stops: one that waited behind the Stage never shows after it.
    var whileTakeRuns = false

    var succeeded: Bool { tone == .success }
    /// The take a notice is about, or its buttons act on; the notice lasts only as long as that take's session.
    var takeID: Int? { forTake ?? actions.lazy.compactMap(\.handler.takeID).first }
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
            message: String(localized: "Auto-export couldn't write to its folder: \(FailureText.message(for: error))"),
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
