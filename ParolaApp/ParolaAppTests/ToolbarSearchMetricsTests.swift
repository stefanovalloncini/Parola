import CoreGraphics
import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Toolbar search metrics")
struct ToolbarSearchMetricsTests {
    private let defaultWindow: CGFloat = 1180

    @Test("only the introduction hides the field")
    func introductionHidesTheField() {
        #expect(ToolbarSearchMetrics.isShown(introductionPresented: false))
        #expect(!ToolbarSearchMetrics.isShown(introductionPresented: true))
    }

    @Test("an unmeasured window keeps the field rather than flashing the chip")
    func unmeasuredWindowKeepsTheField() {
        #expect(!ToolbarSearchMetrics.collapses(windowWidth: 0, intakeShown: true))
        #expect(!ToolbarSearchMetrics.collapses(windowWidth: 0, intakeShown: false))
    }

    @Test("the window minimum collapses the field while the intake capsule is beside it")
    func windowMinimumCollapses() {
        #expect(ToolbarSearchMetrics.collapses(windowWidth: MainWindowLayout.minimumWidth, intakeShown: true))
    }

    @Test("the same window keeps the field on a page with no intake capsule")
    func windowMinimumWithoutIntakeKeepsTheField() {
        #expect(!ToolbarSearchMetrics.collapses(windowWidth: MainWindowLayout.minimumWidth, intakeShown: false))
    }

    @Test("the default window keeps the field either way")
    func defaultWindowKeepsTheField() {
        #expect(!ToolbarSearchMetrics.collapses(windowWidth: defaultWindow, intakeShown: true))
        #expect(!ToolbarSearchMetrics.collapses(windowWidth: defaultWindow, intakeShown: false))
    }

    @Test("widening a window never takes the field away")
    func wideningNeverCollapses() {
        for intakeShown in [true, false] {
            var wasOpen = false
            for width in stride(from: 600.0, through: 1600.0, by: 10.0) {
                let open = !ToolbarSearchMetrics.collapses(windowWidth: width, intakeShown: intakeShown)
                #expect(!(wasOpen && !open))
                wasOpen = open
            }
        }
    }

    @Test("hiding the intake capsule never takes the field away either")
    func hidingTheCapsuleNeverCollapses() {
        for width in stride(from: 600.0, through: 1600.0, by: 10.0) {
            if !ToolbarSearchMetrics.collapses(windowWidth: width, intakeShown: true) {
                #expect(!ToolbarSearchMetrics.collapses(windowWidth: width, intakeShown: false))
            }
        }
    }

    @Test("the field rests narrow and widens for the keyboard")
    func restingAndFocusedWidths() {
        #expect(ToolbarSearchMetrics.focusedWidth > ToolbarSearchMetrics.restingWidth)
        #expect(
            ToolbarSearchMetrics.fieldWidth(windowWidth: defaultWindow, intakeShown: true, focused: false)
                == ToolbarSearchMetrics.restingWidth
        )
        #expect(
            ToolbarSearchMetrics.fieldWidth(windowWidth: defaultWindow, intakeShown: true, focused: true)
                == ToolbarSearchMetrics.focusedWidth
        )
    }

    @Test("a chip opened at the window minimum expands into the room that is left, not past it")
    func expandingAtTheWindowMinimumStaysInside() {
        let room = ToolbarSearchMetrics.roomForSearch(windowWidth: MainWindowLayout.minimumWidth, intakeShown: true)
        for focused in [true, false] {
            let width = ToolbarSearchMetrics.fieldWidth(
                windowWidth: MainWindowLayout.minimumWidth,
                intakeShown: true,
                focused: focused
            )
            #expect(width <= room)
            #expect(width >= ToolbarSearchMetrics.minimumFieldWidth)
        }
    }

    @Test("Esc clears a query and hands the keyboard back when there is none")
    func escapeOutcomes() {
        #expect(ToolbarSearchMetrics.escape(isEmpty: false) == .clear)
        #expect(ToolbarSearchMetrics.escape(isEmpty: true) == .resignFocus)
    }
}
