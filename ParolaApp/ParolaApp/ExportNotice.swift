import Foundation

/// How an export the user asked for went, when there is something to say: it failed, or a bulk export
/// finished and counts what it wrote. The open transcript stays on screen either way.
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

    var succeeded: Bool { failures.isEmpty && folder != nil }

    static func failed(_ error: Error) -> ExportNotice {
        ExportNotice(message: AppModel.exportFailureMessage(for: error), failures: [], folder: nil)
    }

    static func bulk(exported: Int, of total: Int, failures: [Failure], folder: URL) -> ExportNotice {
        ExportNotice(
            message: String(localized: "Exported \(exported) of \(total)"),
            failures: failures,
            folder: folder
        )
    }
}
