import SwiftUI

/// Marks the caret's place at the end of a live text, so the caret's own view can sit over it.
struct LiveCaretMark: TextAttribute {}

/// The live caret on a view of its own, over a transparent one the text ends with: a blink redraws the caret, never the paragraph.
struct LiveCaret: View {
    let font: Font
    /// Where the placeholder sits on its baseline.
    let origin: CGPoint
    let blinks: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()

    /// Ends the text, transparent, so its lines break with room for the caret.
    static var placeholder: Text {
        StreamingReveal.caret(visible: false).customAttribute(LiveCaretMark())
    }

    var body: some View {
        if blinks, !reduceMotion {
            TimelineView(.periodic(from: epoch, by: StreamingReveal.caretBlinkPeriod)) { context in
                let ticks = Int(context.date.timeIntervalSince(epoch) / StreamingReveal.caretBlinkPeriod)
                glyph.opacity(ticks.isMultiple(of: 2) ? 1 : 0)
            }
        } else {
            glyph
        }
    }

    // Drawn rather than laid out: a view lands on whole pixels, the text's own glyphs don't.
    private var glyph: some View {
        Canvas { context, _ in
            let caret = context.resolve(StreamingReveal.caret(visible: true).font(font))
            let size = caret.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            let top = origin.y - caret.firstBaseline(in: size)
            context.draw(caret, in: CGRect(origin: CGPoint(x: origin.x, y: top), size: size))
        }
    }

    /// Where the placeholder sits on its baseline, in the space `proxy` reads.
    static func origin(in layouts: [Text.LayoutKey.AnchoredLayout], proxy: GeometryProxy) -> CGPoint? {
        for anchored in layouts.reversed() {
            for line in anchored.layout.reversed() {
                for run in line.reversed() where run[LiveCaretMark.self] != nil {
                    let origin = proxy[anchored.origin]
                    let bounds = run.typographicBounds
                    return CGPoint(x: origin.x + bounds.origin.x, y: origin.y + bounds.origin.y)
                }
            }
        }
        return nil
    }
}

extension View {
    /// Lays the live caret over the placeholder this text ends with.
    func liveCaret(font: Font, blinks: Bool) -> some View {
        overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                if let origin = LiveCaret.origin(in: layouts, proxy: proxy) {
                    LiveCaret(font: font, origin: origin, blinks: blinks)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
