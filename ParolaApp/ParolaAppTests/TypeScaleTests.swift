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

    /// Width as well as height: two tiers can share a line height and differ in weight or design.
    private func measured(_ font: Font) -> CGSize {
        NSHostingView(rootView: Text(verbatim: "Hxg 019").font(font)).fittingSize
    }

    @Test("every legacy name renders as the tier it aliases")
    func legacyNamesRenderAsTheirTier() {
        // The measurement has to be able to fail: weight and design both move it.
        #expect(measured(DS.Font.body) != measured(DS.Font.bodyStrong))
        #expect(measured(DS.Font.secondary) != measured(DS.Font.mono))

        let aliases: [(Comment, Font, Font)] = [
            ("largeTitle", DS.Font.largeTitle, DS.Font.display),
            ("title3", DS.Font.title3, DS.Font.heading),
            ("callout", DS.Font.callout, DS.Font.secondary),
            ("subheadline", DS.Font.subheadline, DS.Font.secondary),
            ("caption2", DS.Font.caption2, DS.Font.caption),
            ("captionMedium", DS.Font.captionMedium, DS.Font.caption),
            ("bodyEmphasized", DS.Font.bodyEmphasized, DS.Font.bodyStrong),
            ("bodyMedium", DS.Font.bodyMedium, DS.Font.bodyStrong),
            ("calloutMedium", DS.Font.calloutMedium, DS.Font.bodyStrong),
            ("subheadlineEmphasized", DS.Font.subheadlineEmphasized, DS.Font.bodyStrong),
            ("bodyMono", DS.Font.bodyMono, DS.Font.mono),
            ("calloutMono", DS.Font.calloutMono, DS.Font.mono),
            ("subheadlineMono", DS.Font.subheadlineMono, DS.Font.mono),
            ("captionMono", DS.Font.captionMono, DS.Font.mono),
            ("caption2Mono", DS.Font.caption2Mono, DS.Font.mono),
        ]
        for (name, alias, tier) in aliases {
            #expect(measured(alias) == measured(tier), name)
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
