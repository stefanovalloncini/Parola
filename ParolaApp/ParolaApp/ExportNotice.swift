import Foundation

/// A failed export or a bulk export's count, shown without taking the open transcript's place.
struct ExportNotice: Equatable, Identifiable {
    struct Failure: Equatable {
        let name: String
        let reason: String
    }

    let id = UUID()
    let message: String
    let failures: [Failure]
    /// Where a bulk export wrote, for Reveal.
    let folder: URL?
    var offersFolderChoice = false

    var succeeded: Bool { failures.isEmpty && folder != nil }

    static func failed(_ error: Error) -> ExportNotice {
        ExportNotice(message: AppModel.exportFailureMessage(for: error), failures: [], folder: nil)
    }

    static var autoExportFolderMissing: ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export skipped this transcript: recordings and links save to an auto-export folder, and none is chosen yet. Choose one in Settings › Auto-Export."),
            failures: [], folder: nil, offersFolderChoice: true
        )
    }

    static var autoExportFolderUnavailable: ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export can't reach its folder. Choose it again in Settings › Auto-Export."),
            failures: [], folder: nil, offersFolderChoice: true
        )
    }

    static func autoExportFailed(_ error: Error) -> ExportNotice {
        ExportNotice(
            message: String(localized: "Auto-export couldn't write to its folder: \(error.localizedDescription)"),
            failures: [], folder: nil, offersFolderChoice: true
        )
    }

    static func bulk(exported: Int, of total: Int, failures: [Failure], folder: URL) -> ExportNotice {
        ExportNotice(
            message: String(localized: "Exported \(exported) of \(total)"),
            failures: failures,
            folder: folder
        )
    }
}

/// The folder a take's or a link's auto-exports go to: a bookmark, so a moved folder is still found.
struct AutoExportFolder: Codable, Equatable, Sendable {
    var bookmark: Data
    var path: String
}
