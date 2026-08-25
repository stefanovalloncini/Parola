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

    static var transcriptPaneMinWidth: CGFloat {
        transcriptMinWidth + dividerWidth + inspectorWidth
    }
}
