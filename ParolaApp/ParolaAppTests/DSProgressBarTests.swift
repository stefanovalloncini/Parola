import Testing
@testable import Parola

@MainActor
@Suite("DS progress bar fill")
struct DSProgressBarTests {

    @Test("fill defaults to the accent color")
    func defaultsToAccent() {
        let bar = DSProgressBar(value: 0.5)
        #expect(bar.fill == nil)
        #expect(bar.resolvedFill == DS.Color.accent)
    }

    @Test("an explicit fill overrides the accent default")
    func explicitFillWins() {
        let bar = DSProgressBar(value: 0.5, fill: DS.Color.danger)
        #expect(bar.resolvedFill == DS.Color.danger)
    }

    @Test("a bar is as thick as the design system says unless a caller asks for thinner")
    func heightDefaultsToTheToken() {
        #expect(DSProgressBar(value: 0.5).height == DS.Size.progressBarHeight)
        #expect(DSProgressBar(value: 0.5, height: RecentlyDeletedRow.expiryBarHeight).height == 3)
        #expect(RecentlyDeletedRow.expiryBarHeight < DS.Size.progressBarHeight)
    }
}
