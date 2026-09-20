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
        #expect(height(DS.Font.transcript) == height(DS.Font.heading))
        #expect(height(DS.Font.transcriptCompact) == height(DS.Font.body))
    }

    /// Width as well as height: two tiers can share a line height and differ in weight or design.
    private func measured(_ font: Font) -> CGSize {
        NSHostingView(rootView: Text(verbatim: "Hxg 019").font(font)).fittingSize
    }

    @Test("tiers that share a line height still differ on screen")
    func tiersSharingAHeightDiffer() {
        #expect(measured(DS.Font.body) != measured(DS.Font.bodyStrong))
        #expect(measured(DS.Font.secondary) != measured(DS.Font.mono))
        #expect(measured(DS.Font.transcript) != measured(DS.Font.heading))
    }

    @Test("a section caption is the caption tier, not a one-off")
    func sectionCaptionUsesTheCaptionTier() {
        let caption = NSHostingView(rootView: SectionCaption("Library"))
        let reference = NSHostingView(rootView: Text(verbatim: "LIBRARY").font(DS.Font.caption).tracking(0.6))
        #expect(caption.fittingSize.height == reference.fittingSize.height)
        #expect(abs(caption.fittingSize.width - reference.fittingSize.width) < 0.5)
    }
}
