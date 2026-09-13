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

    @Test("every legacy name resolves to a tier")
    func legacyNamesAreAliases() {
        #expect(DS.Font.largeTitle == DS.Font.display)
        #expect(DS.Font.title3 == DS.Font.heading)
        #expect(DS.Font.callout == DS.Font.secondary)
        #expect(DS.Font.subheadline == DS.Font.secondary)
        #expect(DS.Font.caption2 == DS.Font.caption)
        #expect(DS.Font.captionMedium == DS.Font.caption)
        #expect(DS.Font.bodyEmphasized == DS.Font.bodyStrong)
        #expect(DS.Font.bodyMedium == DS.Font.bodyStrong)
        #expect(DS.Font.calloutMedium == DS.Font.bodyStrong)
        #expect(DS.Font.subheadlineEmphasized == DS.Font.bodyStrong)
        for mono in [DS.Font.bodyMono, DS.Font.calloutMono, DS.Font.subheadlineMono, DS.Font.captionMono, DS.Font.caption2Mono] {
            #expect(mono == DS.Font.mono)
        }
    }

    @Test("a section caption is the caption tier, not a one-off")
    func sectionCaptionUsesTheCaptionTier() {
        let caption = NSHostingView(rootView: SectionCaption("Library"))
        let reference = NSHostingView(rootView: Text(verbatim: "LIBRARY").font(DS.Font.caption).tracking(0.6))
        #expect(caption.fittingSize.height == reference.fittingSize.height)
        #expect(abs(caption.fittingSize.width - reference.fittingSize.width) < 0.5)
    }
}
