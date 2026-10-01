import AppKit
import SwiftUI
import Testing
@testable import Parola

@Suite("Stage layout")
struct StageLayoutTests {
    @MainActor
    private func measured(_ font: Font, text: String = "Hxg 019") -> CGSize {
        NSHostingView(rootView: Text(verbatim: text).font(font)).fittingSize
    }

    @Test("the unsettled words clear 4.5:1 on every backdrop the Stage sits on")
    func liveTailIsLegible() {
        let tail = DS.Color.liveTailTheme.appearanceVariants
        for backdrop in [ThemePalette.sharedNeutrals.canvas, ThemePalette.sharedNeutrals.surface] {
            let behind = backdrop.appearanceVariants
            #expect(tail.light.contrast(against: behind.light) >= RGBA.textContrastMinimum)
            #expect(tail.dark.contrast(against: behind.dark) >= RGBA.textContrastMinimum)
        }
    }

    @Test("the Stage's clock is 56 pt SF Rounded light with digits of one width")
    @MainActor
    func stageClockFace() {
        #expect(measured(DS.Font.takeTimerStage) == measured(.system(size: 56, weight: .light, design: .rounded).monospacedDigit()))
        #expect(measured(DS.Font.takeTimerStage) != measured(.system(size: 56, weight: .light, design: .monospaced).monospacedDigit()))
        #expect(measured(DS.Font.takeTimerStage, text: "0:00") == measured(DS.Font.takeTimerStage, text: "1:11"))
        #expect(measured(DS.Font.takeTimerCompact, text: "0:00") == measured(DS.Font.takeTimerCompact, text: "1:11"))
    }

    @Test("the Stage's words are New York 24")
    @MainActor
    func stageTextFace() {
        #expect(measured(DS.Font.liveTranscriptStage) == measured(.system(size: 24, design: .serif)))
        #expect(measured(DS.Font.liveTranscriptStage) != measured(.system(size: 24)))
    }
}
