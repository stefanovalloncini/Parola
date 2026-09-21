import Foundation
import Testing
@testable import Parola

@Suite("Page header metrics")
struct PageHeaderMetricsTests {
    /// The window's own minimum, less the sidebar it always carries.
    private func paneWidth(window: CGFloat, sidebar: CGFloat = MainWindowLayout.sidebarIdealWidth) -> CGFloat {
        window - sidebar - MainWindowLayout.dividerWidth
    }

    @Test("a header that has not been measured keeps the full field")
    func unmeasuredStaysExpanded() {
        #expect(!PageHeaderMetrics.collapsesSearch(width: 0))
    }

    @Test("the window minimum collapses the field, whatever the sidebar is set to")
    func narrowestWindowCollapses() {
        for sidebar in [MainWindowLayout.sidebarMinWidth, MainWindowLayout.sidebarIdealWidth, MainWindowLayout.sidebarMaxWidth] {
            let pane = paneWidth(window: MainWindowLayout.minimumWidth, sidebar: sidebar)
            #expect(PageHeaderMetrics.collapsesSearch(width: pane))
        }
    }

    @Test("a comfortable window keeps the field")
    func roomyWindowKeepsTheField() {
        #expect(!PageHeaderMetrics.collapsesSearch(width: paneWidth(window: 1180)))
        #expect(!PageHeaderMetrics.collapsesSearch(width: paneWidth(window: 1440)))
    }

    @Test("the threshold sits between the two window sizes the pages are checked at")
    func thresholdSeparatesTheTwoSizes() {
        #expect(paneWidth(window: MainWindowLayout.minimumWidth) < PageHeaderMetrics.searchCollapseWidth)
        #expect(paneWidth(window: 1180) > PageHeaderMetrics.searchCollapseWidth)
    }
}
