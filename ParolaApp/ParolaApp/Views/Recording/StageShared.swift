import AppKit
import SwiftUI

/// The take's time in whole seconds of capture, pauses left out; it stands still while the take pauses or finishes.
struct StageClock: View {
    let take: RecordingSession
    let font: Font
    var rolls = false
    /// Off while the Stage is out of sight, so the clock stops ticking.
    var ticks = true
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func text(seconds: Int) -> String {
        AppFormat.elapsed(TimeInterval(seconds))
    }

    nonisolated static let rollDuration: TimeInterval = 0.2
    /// How far a digit climbs into place, and out of it: a short climb, as `numericText` rolls.
    nonisolated static let rollClimb: CGFloat = 18
    /// The roll's frames: about thirty a second, like the band's slide.
    nonisolated static let rollFrames = 6
    nonisolated static let rollKey = "roll"

    /// Each character with its place counted from the right, so a digit keeps its identity as the clock grows and only the ones that change roll.
    nonisolated static func places(_ text: String) -> [(place: Int, character: Character)] {
        text.enumerated().map { (text.count - 1 - $0.offset, $0.element) }
    }

    /// Only a clock a landing can carry into the media bar's duration shrinks with its frame; a running one keeps its size.
    nonisolated static func minimumScale(_ state: RecordingSession.State) -> CGFloat {
        StageLanding.stageOffers(state) ? 0.1 : 1
    }

    /// The digits roll on layers while the clock keeps its size; under Reduce Motion, or once a landing may shrink it, SwiftUI draws them and they swap.
    nonisolated static func rollsOnLayers(rolls: Bool, reduceMotion: Bool, state: RecordingSession.State) -> Bool {
        rolls && !reduceMotion && minimumScale(state) == 1
    }

    /// How far through the roll each frame shows the digits, eased out, each frame at the middle of its time.
    nonisolated static var rollProgress: [Double] {
        (0..<rollFrames).map { UnitCurve.easeOut.value(at: (Double($0) + 0.5) / Double(rollFrames)) }
    }

    /// A digit rising into place from below as it fades in, or out of it upwards as it fades out, in held frames, each on a whole device pixel.
    static func rollAnimation(entering: Bool, scale: CGFloat) -> CAAnimationGroup {
        let progress = rollProgress
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = progress.map { done in
            let offset = entering ? rollClimb * (1 - done) : -rollClimb * done
            return (offset * scale).rounded() / scale
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = progress.map { entering ? $0 : 1 - $0 }
        let group = CAAnimationGroup()
        for animation in [rise, fade] {
            // Held values, so the render server draws the roll at its own frame rate rather than the display's.
            animation.calculationMode = .discrete
            animation.keyTimes = (0...rollFrames).map { NSNumber(value: Double($0) / Double(rollFrames)) }
            animation.duration = rollDuration
            animation.preferredFrameRateRange = .roll
        }
        group.animations = [rise, fade]
        group.duration = rollDuration
        group.preferredFrameRateRange = .roll
        return group
    }

    var body: some View {
        let seconds = Int(take.elapsed(at: model?.takeClockNow(following: ticks && take.state == .recording) ?? Date()))
        let text = Self.text(seconds: seconds)
        let layered = Self.rollsOnLayers(rolls: rolls, reduceMotion: reduceMotion, state: take.state)
        return HStack(spacing: 0) {
            ForEach(Self.places(text), id: \.place) { place in
                Text(verbatim: String(place.character))
            }
        }
        .opacity(layered ? 0 : 1)
        .overlay {
            if layered {
                RollingDigits(text: text, font: font)
            }
        }
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(Self.minimumScale(take.state))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording time")
        .accessibilityValue(AppFormat.spokenDuration(seconds: seconds))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The clock's characters on layers the render server rolls, so a turning second costs SwiftUI one update rather than one a frame.
    final class DigitsView: NSView {
        /// One place's character, and the one rolling out of it.
        final class Place {
            let shown = CALayer()
            let leaving = CALayer()
            fileprivate(set) var character: Character?
        }

        private let row = CALayer()
        private(set) var places: [Int: Place] = [:]
        private(set) var text = ""
        private var font: Font?
        private var ink: Color.Resolved?
        private var builtScale: CGFloat?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            // Top down, the way SwiftUI lays the characters out.
            row.isGeometryFlipped = true
            row.anchorPoint = .zero
            layer?.addSublayer(row)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func setFrameSize(_ newSize: NSSize) {
            let resized = newSize != frame.size
            super.setFrameSize(newSize)
            if resized { redraw() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            redraw()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            redraw()
        }

        private var scale: CGFloat {
            window?.backingScaleFactor ?? 2
        }

        /// The characters of `text`: one that changed since the last shown rolls, unless the font or the ink changed with it.
        func show(_ text: String, font: Font, ink: Color.Resolved) {
            let restyled = font != self.font || ink != self.ink
            self.text = text
            self.font = font
            self.ink = ink
            CATransaction.withoutActions { build(restyled: restyled) }
        }

        private func redraw() {
            CATransaction.withoutActions { build(restyled: false) }
        }

        private func build(restyled: Bool) {
            guard let font, let ink else { return }
            let scale = scale
            let redrawn = restyled || scale != builtScale
            builtScale = scale
            row.frame = bounds
            var x: CGFloat = 0
            var kept = Set<Int>()
            for (index, character) in StageClock.places(text) {
                guard let glyph = ClockGlyphs.glyph(character, font: font, ink: ink, scale: scale) else { continue }
                let place = places[index] ?? makePlace(index)
                kept.insert(index)
                let origin = CGPoint(x: ((x - ClockGlyphs.bleed) * scale).rounded() / scale, y: -ClockGlyphs.bleed)
                x += glyph.size.width
                let old = place.character
                if redrawn || old != character {
                    let stood = place.shown.frame.origin
                    place.character = character
                    put(glyph, in: place.shown, at: origin, scale: scale)
                    if !redrawn, window != nil, let old, let out = ClockGlyphs.glyph(old, font: font, ink: ink, scale: scale) {
                        put(out, in: place.leaving, at: stood, scale: scale)
                        place.leaving.add(StageClock.rollAnimation(entering: false, scale: scale), forKey: StageClock.rollKey)
                        place.shown.add(StageClock.rollAnimation(entering: true, scale: scale), forKey: StageClock.rollKey)
                    } else {
                        place.shown.removeAnimation(forKey: StageClock.rollKey)
                        place.leaving.removeAnimation(forKey: StageClock.rollKey)
                    }
                } else if place.shown.frame.origin != origin {
                    place.shown.frame.origin = origin
                    place.leaving.frame.origin = origin
                }
            }
            ClockGlyphs.warm(font: font, ink: ink, scale: scale)
            for index in places.keys where !kept.contains(index) {
                places[index]?.shown.removeFromSuperlayer()
                places[index]?.leaving.removeFromSuperlayer()
                places[index] = nil
            }
        }

        private func makePlace(_ index: Int) -> Place {
            let place = Place()
            place.leaving.opacity = 0
            row.addSublayer(place.leaving)
            row.addSublayer(place.shown)
            places[index] = place
            return place
        }

        private func put(_ glyph: ClockGlyph, in layer: CALayer, at origin: CGPoint, scale: CGFloat) {
            layer.contents = glyph.image
            layer.contentsScale = scale
            layer.frame = CGRect(origin: origin, size: CGSize(width: CGFloat(glyph.image.width) / scale, height: CGFloat(glyph.image.height) / scale))
        }
    }
}

/// A clock character as SwiftUI draws it, for the rolling layers to show.
struct ClockGlyph {
    let image: CGImage
    /// The character's own frame, as SwiftUI lays it out, without the bleed around it.
    let size: CGSize
}

/// The clock's characters, each drawn once per font, ink and screen scale.
@MainActor
enum ClockGlyphs {
    /// Room around a character for ink that reaches past its frame.
    static let bleed: CGFloat = 8
    static let characters = "0123456789:"

    private struct Style: Hashable {
        let font: Font
        let ink: Color.Resolved
        let scale: CGFloat
    }

    private static var drawn: [Style: [Character: ClockGlyph]] = [:]
    private static var warmed: Set<Style> = []

    static func glyph(_ character: Character, font: Font, ink: Color.Resolved, scale: CGFloat) -> ClockGlyph? {
        let style = Style(font: font, ink: ink, scale: scale)
        if let glyph = drawn[style]?[character] { return glyph }
        if drawn[style] == nil, drawn.count >= 6 {
            drawn = [:]
            warmed = []
        }
        let glyph = draw(character, style: style)
        drawn[style, default: [:]][character] = glyph
        return glyph
    }

    /// Draws the rest of the clock's characters just after the update that needed the first ones, so no later second draws one inside SwiftUI's update.
    static func warm(font: Font, ink: Color.Resolved, scale: CGFloat) {
        guard warmed.insert(Style(font: font, ink: ink, scale: scale)).inserted else { return }
        DispatchQueue.main.async {
            for character in characters {
                _ = glyph(character, font: font, ink: ink, scale: scale)
            }
        }
    }

    private static func draw(_ character: Character, style: Style) -> ClockGlyph? {
        let scale = style.scale
        let renderer = ImageRenderer(content: Text(verbatim: String(character)).font(style.font).foregroundStyle(Color(style.ink)).padding(bleed))
        // Text sizes round up to the screen's pixels, so a character measured at another scale would sit a pixel off.
        renderer.scale = scale
        var glyph: ClockGlyph?
        renderer.render { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.scaleBy(x: scale, y: scale)
            // The view draws from the bottom of the box it is given; the rounding up goes above it, so lift the view to the image's top.
            context.translateBy(x: 0, y: CGFloat(height) / scale - size.height)
            draw(context)
            guard let image = context.makeImage() else { return }
            glyph = ClockGlyph(image: image, size: CGSize(width: size.width - 2 * bleed, height: size.height - 2 * bleed))
        }
        return glyph
    }
}

/// The clock's characters on their layers; the ink is the Stage's text colour, read from the environment on each update so it follows a switch to dark.
private struct RollingDigits: NSViewRepresentable {
    let text: String
    let font: Font

    func makeNSView(context: Context) -> StageClock.DigitsView {
        StageClock.DigitsView()
    }

    func updateNSView(_ view: StageClock.DigitsView, context: Context) {
        view.show(text, font: font, ink: DS.Color.primaryText.resolve(in: context.environment))
    }
}

extension RecordingSession {
    /// When the take's clock read 0:00, counting its pauses as time it never ran; the clock ticks on whole seconds from here.
    var clockOrigin: Date? {
        startedAt?.addingTimeInterval(pausedTotal)
    }
}

/// The recording light: full strength as each second of the take turns over, easing to 35 % halfway through it.
struct RecDot: View {
    var color: Color = DS.Color.recordingFill
    var side: CGFloat = 8
    var pulsesFrom: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let pulseKey = "pulse"

    var body: some View {
        Group {
            if let origin = Self.pulseOrigin(pulsesFrom, reduceMotion: reduceMotion) {
                PulsingLight(color: color, origin: origin)
            } else {
                Circle()
                    .fill(color)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Nil while the light holds still at full strength: under Reduce Motion, or with nothing to pulse from.
    nonisolated static func pulseOrigin(_ origin: Date?, reduceMotion: Bool) -> Date? {
        reduceMotion ? nil : origin
    }

    nonisolated static func pulse(at elapsed: TimeInterval) -> Double {
        let phase = elapsed - elapsed.rounded(.down)
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }

    /// When the take's current second began, in a layer's time, so a light built at any moment pulses in step with the take.
    nonisolated static func pulseBegin(origin: Date, now: Date, layerTime: CFTimeInterval) -> CFTimeInterval {
        let elapsed = now.timeIntervalSince(origin)
        return layerTime - (elapsed - elapsed.rounded(.down))
    }

    /// How many times a second the light changes strength.
    nonisolated static let pulseSteps = 15

    static func pulseAnimation(beginTime: CFTimeInterval) -> CAKeyframeAnimation {
        let steps = pulseSteps
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        // Held steps, so the render server redraws the light fifteen times a second rather than every frame.
        animation.calculationMode = .discrete
        animation.values = (0..<steps).map { pulse(at: Double($0) / Double(steps)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = 1
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = .pulse
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A layer the render server pulses, so the app does no work for the light from frame to frame.
    final class LightView: NSView {
        let dot = CALayer()
        private var origin: Date?
        private var wakeObserver: (any NSObjectProtocol)?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            dot.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            dot.frame = CGRect(origin: .zero, size: newSize)
            dot.cornerRadius = min(newSize.width, newSize.height) / 2
        }

        // A click on the light belongs to the button it sits in.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWake()
            pulse()
        }

        // Core Animation's clock stands still while the Mac sleeps and the take's doesn't, so a wake starts the loop again in step.
        private func observeWake() {
            let center = NSWorkspace.shared.notificationCenter
            if let wakeObserver { center.removeObserver(wakeObserver) }
            wakeObserver = nil
            guard window != nil else { return }
            wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pulse() }
            }
        }

        func show(_ color: CGColor, pulsingFrom origin: Date) {
            dot.backgroundColor = color
            guard origin != self.origin else { return }
            self.origin = origin
            pulse()
        }

        private func pulse() {
            dot.removeAnimation(forKey: RecDot.pulseKey)
            guard window != nil, let origin else { return }
            let begin = RecDot.pulseBegin(origin: origin, now: Date(), layerTime: dot.convertTime(CACurrentMediaTime(), from: nil))
            dot.add(RecDot.pulseAnimation(beginTime: begin), forKey: RecDot.pulseKey)
        }
    }
}

extension CATransaction {
    static func withoutActions(_ change: () -> Void) {
        begin()
        setDisableActions(true)
        change()
        commit()
    }
}

extension CAFrameRateRange {
    /// What the Stage's render-server motion runs at: about thirty frames a second, the cadence it was filmed at.
    static let stage = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
    /// What the recording light's pulse runs at: its own fifteen steps a second, never more.
    static let pulse = CAFrameRateRange(minimum: 15, maximum: 15, preferred: 15)
    /// What the clock's digit roll runs at: its own thirty frames a second.
    static let roll = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
}

private struct PulsingLight: NSViewRepresentable {
    let color: Color
    let origin: Date

    func makeNSView(context: Context) -> RecDot.LightView {
        RecDot.LightView()
    }

    func updateNSView(_ view: RecDot.LightView, context: Context) {
        view.show(color.resolve(in: context.environment).cgColor, pulsingFrom: origin)
    }
}

/// Whether the window this sits in is on screen: false while it is minimized, hidden with the app, covered, or on another Space.
struct WindowShownReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    nonisolated static func shows(isVisible: Bool, isMiniaturized: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && !isMiniaturized && occlusion.contains(.visible)
    }

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [any NSObjectProtocol] = []
        private var reported: Bool?

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            // A view joins its window inside SwiftUI's update, which must not change the Stage's state.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            let shown = WindowShownReader.shows(
                isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, occlusion: window.occlusionState
            )
            guard shown != reported else { return }
            reported = shown
            onChange?(shown)
        }
    }
}
