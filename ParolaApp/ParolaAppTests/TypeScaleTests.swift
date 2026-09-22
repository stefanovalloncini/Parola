import AppKit
import SwiftUI
import Testing
@testable import Parola

@Suite("Type scale")
@MainActor
struct TypeScaleTests {

    private func height(_ font: Font) -> CGFloat {
        let host = NSHostingView(rootView: Text(verbatim: "Hxg").font(font))
        return host.fittingSize.height
    }

    @Test("the tiers step down in the order the scale declares")
    func tiersDescend() {
        let ladder: [Font] = [
            DS.Font.hero,
            DS.Font.display,
            DS.Font.title,
            DS.Font.heading,
            DS.Font.body,
            DS.Font.secondary,
            DS.Font.caption,
        ]
        for (bigger, smaller) in zip(ladder, ladder.dropFirst()) {
            #expect(height(bigger) > height(smaller))
        }
        #expect(height(DS.Font.bodyStrong) == height(DS.Font.body))
        // The reading tier is New York on its own rhythm, so it steps down within itself, not against chrome.
        #expect(height(DS.Font.transcript) > height(DS.Font.transcriptCompact))
        #expect(height(DS.Font.transcriptCompact) > height(DS.Font.body))
    }

    /// Width as well as height: two tiers can share a line height and differ in weight or design.
    private func measured(_ font: Font, text: String = "Hxg 019") -> CGSize {
        NSHostingView(rootView: Text(verbatim: text).font(font)).fittingSize
    }

    @Test("tiers that share a line height still differ on screen")
    func tiersSharingAHeightDiffer() {
        #expect(measured(DS.Font.body) != measured(DS.Font.bodyStrong))
        #expect(measured(DS.Font.secondary) != measured(DS.Font.mono))
        // transcriptEmphasis is the transcript face at semibold: same line, wider glyphs — the serif's own pair.
        #expect(height(DS.Font.transcriptEmphasis) == height(DS.Font.transcript))
        #expect(measured(DS.Font.transcriptEmphasis) != measured(DS.Font.transcript))
    }

    /// A `Font` carries no readable weight or design, so a tier is pinned by rendering equal to its reference.
    @Test("the three display tiers are bold and the page title below them is not")
    func displayTiersAreBold() {
        #expect(measured(DS.Font.wordmark) == measured(.system(size: 56, weight: .bold)))
        #expect(measured(DS.Font.hero) == measured(.system(size: 40, weight: .bold)))
        #expect(measured(DS.Font.display) == measured(.system(size: 28, weight: .bold)))
        #expect(measured(DS.Font.title) == measured(.system(size: 22, weight: .semibold)))
        #expect(measured(DS.Font.hero) != measured(.system(size: 40, weight: .semibold)))
        #expect(measured(DS.Font.display) != measured(.system(size: 28, weight: .semibold)))
    }

    @Test("the reading tier is New York, the chrome around it is SF")
    func readingTierIsSerif() {
        #expect(measured(DS.Font.transcript) == measured(.system(size: 17, design: .serif)))
        #expect(measured(DS.Font.transcript) != measured(.system(size: 17)))
        #expect(measured(DS.Font.transcriptEmphasis) == measured(.system(size: 17, weight: .semibold, design: .serif)))
        #expect(measured(DS.Font.transcriptEmphasis) != measured(.system(size: 17, weight: .semibold)))
        #expect(measured(DS.Font.transcriptCompact) == measured(.system(size: 15, design: .serif)))
        #expect(measured(DS.Font.transcriptCompact) != measured(.system(size: 15)))
        #expect(measured(DS.Font.body) == measured(.system(size: 13)))
    }

    @Test("the recording timer is rounded and its digits are all one width")
    func timerIsRoundedAndTabular() {
        #expect(measured(DS.Font.timer) == measured(.system(size: 22, weight: .light, design: .rounded).monospacedDigit()))
        #expect(measured(DS.Font.timer) != measured(.system(size: 22, weight: .light, design: .monospaced).monospacedDigit()))
        #expect(measured(DS.Font.timer, text: "00:00") == measured(DS.Font.timer, text: "11:11"))
    }

    @Test("the compact reading tier is the tighter of the two leadings")
    func compactLeadingIsTighter() {
        #expect(DS.Spacing.transcriptLeadingCompact < DS.Spacing.transcriptLeading)
        #expect(DS.Spacing.transcriptLeadingCompact > 0)
    }

    @Test("a section caption is the caption tier, not a one-off")
    func sectionCaptionUsesTheCaptionTier() {
        let caption = NSHostingView(rootView: SectionCaption("Library"))
        let reference = NSHostingView(rootView: Text(verbatim: "LIBRARY").font(DS.Font.caption).tracking(0.6))
        #expect(caption.fittingSize.height == reference.fittingSize.height)
        #expect(abs(caption.fittingSize.width - reference.fittingSize.width) < 0.5)
    }
}
