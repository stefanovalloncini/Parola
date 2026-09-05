import CoreGraphics

enum MainWindowLayout {
    static let minimumWidth: CGFloat = 920
    static let minimumHeight: CGFloat = 600

    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 240
    static let sidebarMaxWidth: CGFloat = 320

    static let transcriptMinWidth: CGFloat = 280
    static let inspectorWidth: CGFloat = 300
    static let dividerWidth: CGFloat = 1

    static let batchQueueMinWidth: CGFloat = 280
    static let batchExportPaneWidth: CGFloat = 300

    static let transcriptReadableWidth: CGFloat = 520

    /// Panes narrower than this fold the inspector away instead of squeezing the reading column.
    static var inspectorCollapseWidth: CGFloat {
        transcriptReadableWidth + dividerWidth + inspectorWidth
    }

    static var transcriptPaneMinWidth: CGFloat {
        transcriptMinWidth + dividerWidth + inspectorWidth
    }

    static var batchPaneMinWidth: CGFloat {
        batchQueueMinWidth + dividerWidth + batchExportPaneWidth
    }

    static var narrowestPaneWidth: CGFloat {
        min(transcriptMinWidth, batchQueueMinWidth)
    }
}
