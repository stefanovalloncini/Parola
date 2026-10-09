import SwiftUI

/// Marks the caret's place at the end of a live text, so the caret's own view can sit over it.
struct LiveCaretMark: TextAttribute {}

/// Where the placeholder caret sits: its baseline origin and the room its line gives it, in the overlay's space.
struct CaretPlace: Equatable {
    var origin: CGPoint
    var ascent: CGFloat
    var descent: CGFloat
    var width: CGFloat

    static func find(in layouts: [Text.LayoutKey.AnchoredLayout], proxy: GeometryProxy) -> CaretPlace? {
        for anchored in layouts.reversed() {
            for line in anchored.layout.reversed() {
                for run in line.reversed() where run[LiveCaretMark.self] != nil {
                    let origin = proxy[anchored.origin]
                    let bounds = run.typographicBounds
                    return CaretPlace(
                        origin: CGPoint(x: origin.x + bounds.origin.x, y: origin.y + bounds.origin.y),
                        ascent: bounds.ascent,
                        descent: bounds.descent,
                        width: bounds.width
                    )
                }
            }
        }
        return nil
    }
}

/// The live caret on a view of its own, over a transparent one the text ends with: a blink changes the caret's opacity, nothing else.
struct LiveCaret: View {
    let font: Font
    let place: CaretPlace
    let blinks: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var epoch = Date()

    /// Ends the text, transparent, so its lines break with room for the caret.
    static var placeholder: Text {
        StreamingReveal.caret(visible: false).customAttribute(LiveCaretMark())
    }

    var body: some View {
        let glyph = CaretGlyph(font: font, place: place, ink: DS.Color.accentInk, scale: displayScale)
            .equatable()
        if blinks, !reduceMotion {
            TimelineView(.periodic(from: epoch, by: StreamingReveal.caretBlinkPeriod)) { context in
                let ticks = Int(context.date.timeIntervalSince(epoch) / StreamingReveal.caretBlinkPeriod)
                glyph.opacity(ticks.isMultiple(of: 2) ? 1 : 0)
            }
        } else {
            glyph
        }
    }
}

/// The caret glyph in a small box set on whole pixels, drawn inside it where the text's own glyph would fall: a view lands on whole pixels, the text's glyphs don't.
struct CaretGlyph: View, Equatable {
    let font: Font
    let place: CaretPlace
    let ink: Color
    let scale: CGFloat

    nonisolated static let bleed: CGFloat = 4

    var body: some View {
        let box = Self.box(for: place, scale: scale)
        Canvas { context, _ in
            let caret = context.resolve(Text(verbatim: StreamingReveal.caretGlyph).font(font).foregroundStyle(ink))
            let size = caret.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            let top = place.origin.y - box.minY - caret.firstBaseline(in: size)
            context.draw(caret, in: CGRect(origin: CGPoint(x: place.origin.x - box.minX, y: top), size: size))
        }
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
    }

    nonisolated static func box(for place: CaretPlace, scale: CGFloat) -> CGRect {
        let onPixel = { (value: CGFloat) in (value * scale).rounded(.down) / scale }
        let x = onPixel(place.origin.x - bleed)
        let y = onPixel(place.origin.y - place.ascent - bleed)
        return CGRect(
            x: x,
            y: y,
            width: (place.origin.x + place.width + bleed - x).rounded(.up),
            height: (place.origin.y + place.descent + bleed - y).rounded(.up)
        )
    }
}

extension View {
    /// Lays the live caret over the placeholder this text ends with.
    func liveCaret(font: Font, blinks: Bool) -> some View {
        overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                if let place = CaretPlace.find(in: layouts, proxy: proxy) {
                    LiveCaret(font: font, place: place, blinks: blinks)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
