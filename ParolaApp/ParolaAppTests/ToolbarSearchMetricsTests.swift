import CoreGraphics
import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Toolbar search metrics")
struct ToolbarSearchMetricsTests {
    private let defaultWindow: CGFloat = 1180
    private let capsule = ToolbarSearchMetrics.defaultIntakeWidth

    private func collapses(_ windowWidth: CGFloat, intakeWidth: CGFloat, isFocused: Bool = false) -> Bool {
        ToolbarSearchMetrics.collapses(windowWidth: windowWidth, intakeWidth: intakeWidth, isFocused: isFocused)
    }

    @Test("only the introduction hides the field")
    func introductionHidesTheField() {
        #expect(ToolbarSearchMetrics.isShown(introductionPresented: false))
        #expect(!ToolbarSearchMetrics.isShown(introductionPresented: true))
    }

    @Test("an unmeasured window keeps the field rather than flashing the chip")
    func unmeasuredWindowKeepsTheField() {
        #expect(!collapses(0, intakeWidth: capsule))
        #expect(!collapses(0, intakeWidth: 0))
    }

    @Test("the window minimum collapses the field while the intake capsule is beside it")
    func windowMinimumCollapses() {
        #expect(collapses(MainWindowLayout.minimumWidth, intakeWidth: capsule))
    }

    @Test("the same window keeps the field on a page with no intake capsule")
    func windowMinimumWithoutIntakeKeepsTheField() {
        #expect(!collapses(MainWindowLayout.minimumWidth, intakeWidth: 0))
    }

    @Test("the default window keeps the field either way")
    func defaultWindowKeepsTheField() {
        #expect(!collapses(defaultWindow, intakeWidth: capsule))
        #expect(!collapses(defaultWindow, intakeWidth: 0))
    }

    @Test("the rule follows the capsule it is given, not a fixed one")
    func widerCapsuleCollapsesSooner() {
        #expect(!collapses(1000, intakeWidth: capsule))
        #expect(collapses(1000, intakeWidth: capsule + 120))
    }

    @Test("a field holding the keyboard is never taken away")
    func focusedFieldNeverCollapses() {
        #expect(!collapses(MainWindowLayout.minimumWidth, intakeWidth: capsule, isFocused: true))
        #expect(!collapses(600, intakeWidth: capsule, isFocused: true))
    }

    @Test("widening a window never takes the field away")
    func wideningNeverCollapses() {
        for intakeWidth in [capsule, 0] {
            var wasOpen = false
            for width in stride(from: 600.0, through: 1600.0, by: 10.0) {
                let open = !collapses(width, intakeWidth: intakeWidth)
                #expect(!(wasOpen && !open))
                wasOpen = open
            }
        }
    }

    @Test("hiding the intake capsule never takes the field away either")
    func hidingTheCapsuleNeverCollapses() {
        for width in stride(from: 600.0, through: 1600.0, by: 10.0) {
            if !collapses(width, intakeWidth: capsule) {
                #expect(!collapses(width, intakeWidth: 0))
            }
        }
    }

    @Test("the field rests narrow and widens for the keyboard")
    func restingAndFocusedWidths() {
        #expect(ToolbarSearchMetrics.focusedWidth > ToolbarSearchMetrics.restingWidth)
        #expect(
            ToolbarSearchMetrics.fieldWidth(windowWidth: defaultWindow, intakeWidth: capsule, focused: false)
                == ToolbarSearchMetrics.restingWidth
        )
        #expect(
            ToolbarSearchMetrics.fieldWidth(windowWidth: defaultWindow, intakeWidth: capsule, focused: true)
                == ToolbarSearchMetrics.focusedWidth
        )
    }

    @Test("a chip opened at the window minimum expands into the room that is left, not past it")
    func expandingAtTheWindowMinimumStaysInside() {
        let room = ToolbarSearchMetrics.roomForSearch(
            windowWidth: MainWindowLayout.minimumWidth,
            intakeWidth: capsule
        )
        for focused in [true, false] {
            let width = ToolbarSearchMetrics.fieldWidth(
                windowWidth: MainWindowLayout.minimumWidth,
                intakeWidth: capsule,
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
