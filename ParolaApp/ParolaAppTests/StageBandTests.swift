import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

/// The tape layer views a hosted view put up, as AppKit holds them.
@MainActor
private func tapeViews(in hosted: HostedWindow) -> [StageBand.TapeView] {
    func views(in view: NSView) -> [StageBand.TapeView] {
        ((view as? StageBand.TapeView).map { [$0] } ?? []) + view.subviews.flatMap(views(in:))
    }
    hosted.host.layoutSubtreeIfNeeded()
    return views(in: hosted.host)
}

/// A lane's bars, as its mask holds them.
@MainActor
private func bars(_ view: StageBand.TapeView, lane: Int = 0) -> CGPath? {
    guard view.lanes.indices.contains(lane) else { return nil }
    return (view.lanes[lane].mask as? CAShapeLayer)?.path
}

/// A lane's ink from its top to its foot.
@MainActor
private func inks(_ lane: CAGradientLayer?) -> [CGColor] {
    lane?.colors as? [CGColor] ?? []
}

private func rgba(_ color: CGColor?) -> [CGFloat] {
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
    return color?.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components ?? []
}

private func sameColor(_ a: CGColor?, _ b: CGColor?) -> Bool {
    let lhs = rgba(a)
    let rhs = rgba(b)
    return lhs.count == 4 && rhs.count == 4 && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.01 }
}

@Suite("Stage band")
struct StageBandTests {
    @Test("the playhead stands at 70 % of the band on a whole point")
    func playhead() {
        #expect(StageBand.playheadX(width: 1180) == 826)
        #expect(StageBand.playheadX(width: 920) == 644)
    }

    @Test("the newest bar sits against the playhead and each older one 5 pt further left")
    func barsStepLeft() {
        #expect(StageBand.barX(offset: 0, playheadX: 826) == 821)
        #expect(StageBand.barX(offset: 1, playheadX: 826) == 816)
        #expect(StageBand.barX(offset: 10, playheadX: 826) == 771)
    }

    @Test("a sample's slide begins at the sample's moment: an update that comes late starts part way through, one dated early waits")
    func slideBegin() {
        let sampled = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(StageBand.slideBegin(sampledAt: sampled, now: sampled, layerTime: 100) == 100)
        let late = StageBand.slideBegin(sampledAt: sampled, now: sampled.addingTimeInterval(0.03), layerTime: 100)
        #expect(abs(late - 99.97) < 0.000_001, "30 ms late, so 30 % of the way along")
        let early = StageBand.slideBegin(sampledAt: sampled, now: sampled.addingTimeInterval(-0.01), layerTime: 100)
        #expect(abs(early - 100.01) < 0.000_001, "a frame dated a moment before its sample")
    }

    @MainActor
    @Test("the bars slide one step left over one sample's time in three frames, about thirty a second, each on the device pixel nearest the distance travelled")
    func slideAnimation() {
        let slide = StageBand.slideAnimation(beginTime: 42, scale: 2)
        let values = (slide.values as? [NSNumber])?.map(\.doubleValue) ?? []
        let times = slide.keyTimes?.map(\.doubleValue) ?? []
        let onePoint = StageBand.slideAnimation(beginTime: 0, scale: 1).values as? [NSNumber]

        #expect(StageBand.step == 5)
        #expect(slide.keyPath == "transform.translation.x")
        #expect(slide.calculationMode == .discrete)
        #expect(values == [0, -1.5, -3.5], "5/3 and 10/3 pt on the nearest 2x pixel; the last step is the layer's own resting place")
        #expect(times == [0, 1.0 / 3, 2.0 / 3, 1])
        #expect(onePoint == [0, -2, -3], "whole points at 1x")
        #expect(slide.duration == 1 / TakeLevelHistory.samplesPerSecond)
        #expect(slide.beginTime == 42)
        #expect(!slide.isAdditive)
        #expect(slide.fillMode == .backwards, "until it begins the bars stand against the playhead")
        #expect(slide.preferredFrameRateRange == CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30))
    }

    @Test("under Reduce Motion the band redraws four times a second and never slides")
    func reduceMotionCadence() {
        #expect(StageBand.cadence(reduceMotion: false) == .glides)
        #expect(StageBand.cadence(reduceMotion: true) == .steps(every: 0.25))
    }

    @Test("only for VoiceOver does the band's body read each new sample of a live take; its layer view follows them alone")
    func swiftUIFollowsOnlyForVoiceOver() {
        #expect(StageBand.swiftUIFollowsSamples(live: true, voiceOver: true))
        #expect(!StageBand.swiftUIFollowsSamples(live: true, voiceOver: false))
        #expect(!StageBand.swiftUIFollowsSamples(live: false, voiceOver: true))
    }

    @Test("the bars are built again when a sample, a marker or a pause comes in, and only then")
    func tapeRedrawsPerSample() {
        let tape = StageTape(levels: [0.1, 0.2], flags: [], newest: 41, paused: false)
        #expect(tape == StageTape(levels: [0.1, 0.2], flags: [], newest: 41, paused: false))
        #expect(tape != StageTape(levels: [0.2, 0.3], flags: [], newest: 42, paused: false))
        #expect(tape != StageTape(levels: [0.1, 0.2], flags: [0], newest: 41, paused: false))
        #expect(tape != StageTape(levels: [0.1, 0.2], flags: [], newest: 41, paused: true))
    }

    @Test("a marker stands at its moment in the take until it scrolls out of the band")
    func markers() {
        #expect(StageBand.markerOffset(10.0, newestSample: 99) == 0)
        #expect(StageBand.markerOffset(10.4, newestSample: 99) == 0)
        #expect(StageBand.markerOffset(8.0, newestSample: 99) == 19)
        #expect(StageBand.markerOffset(0, newestSample: StageBand.visibleSamples - 1) == StageBand.visibleSamples - 1)
        #expect(StageBand.markerOffset(0, newestSample: StageBand.visibleSamples) == nil)
    }

    @MainActor
    @Test("a take's levels keep every sample the band can show")
    func historyCoversTheBand() {
        #expect(TakeLevelHistory().recentCapacity >= StageBand.visibleSamples)
    }

    private func level(dBFS: Float) -> Float {
        (dBFS - LevelBars.meterFloorDBFS) / -LevelBars.meterFloorDBFS
    }

    private func bar(dBFS: Float) -> CGFloat {
        LevelBars.height(for: level(dBFS: dBFS), idle: 3, max: 124)
    }

    @Test("room noise rests at the idle height, speech climbs evenly in dB, and only near full scale fills the band")
    func barCurve() {
        #expect(bar(dBFS: -55) == 3)
        #expect(bar(dBFS: -50) == 3)
        #expect(bar(dBFS: -33) == 3)
        #expect(abs(LevelBars.fraction(for: level(dBFS: -20)) - 0.5) < 0.05)
        #expect(abs(bar(dBFS: -6) - 124) < 0.01)
        #expect(bar(dBFS: 0) == 124)
        #expect(LevelBars.fraction(for: .nan) == 0)
    }

    private func toneWAV(dBFS: Double) throws -> URL {
        let rate = 16_000
        let peak = pow(10, dBFS / 20) * 2.squareRoot()
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let samples = (0..<rate).map { Int16(32_767 * peak * sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + samples.count * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(samples.count * 2))
        for sample in samples { le16(UInt16(bitPattern: sample)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-test-band-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    @Test("a voice at -20 dBFS through a real capture's meter draws a bar about half the band")
    func meterToBand() async throws {
        let tone = try toneWAV(dBFS: -20)
        defer { try? FileManager.default.removeItem(at: tone) }
        let capture = FixtureAudioSource.make(fixtureURL: tone, clock: ContinuousClock())
        try await capture.start()
        let heard = await waitUntil { capture.levelMeter.firstReadingAt != nil }
        let reading = capture.levelMeter.level
        await capture.cancel()
        #expect(heard)
        #expect(abs(LevelBars.fraction(for: reading) - 13.0 / 27.0) < 0.03)
    }
}

@MainActor
@Suite("Stage band layers")
struct StageBandLayerTests {
    private let ink = CGColor(gray: 0, alpha: 0.85)
    private let accent = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)
    private let heldStep = CGAffineTransform(translationX: -StageBand.step, y: 0)

    private func tapeView(width: CGFloat = 1180, height: CGFloat = StageBand.height) -> StageBand.TapeView {
        let view = StageBand.TapeView()
        view.setFrameSize(CGSize(width: width, height: height))
        return view
    }

    /// A band in a window, its layers committed once, so a change made to them now would animate unless told not to.
    private func hostedTapeView(_ tape: StageTape) throws -> (HostedWindow, StageBand.TapeView) {
        let hosted = HostedWindow(tape.drawn(.held), width: 1180, height: StageBand.height)
        let found = tapeViews(in: hosted).first
        return (hosted, try #require(found))
    }

    @Test("a new sample's bars and the slide from its moment are set in one change, with nothing animated implicitly")
    func newSampleInOneChange() throws {
        let (hosted, view) = try hostedTapeView(StageTape(levels: [0.2, 0.9], flags: [], newest: 41, paused: false))
        defer { hosted.close() }
        let before = bars(view)
        let sampled = Date(timeIntervalSinceNow: -0.03)
        view.show(StageTape(levels: [0.2, 0.9, 0.5], flags: [0], newest: 42, paused: false), slide: .from(sampled), ink: ink, accent: accent)
        let expectedBegin = StageBand.slideBegin(sampledAt: sampled, now: Date(), layerTime: view.tape.convertTime(CACurrentMediaTime(), from: nil))
        let after = bars(view)
        let slide = try #require(view.tape.animation(forKey: StageBand.slideKey))
        let layers = [view.tape, view.poles, view.pennants] + view.lanes + view.lanes.compactMap(\.mask)
        let implicit = layers.flatMap { $0.animationKeys() ?? [] }.filter { $0 != StageBand.slideKey }

        #expect(after != before, "the new sample's bars")
        #expect(view.pennants.path?.isEmpty == false, "and its flag")
        #expect(abs(slide.beginTime - expectedBegin) < 0.005, "the slide restarted from the new sample's moment")
        #expect(slide.preferredFrameRateRange == CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30))
        #expect(implicit.isEmpty, "implicit animations: \(implicit)")
    }

    @Test("an update that comes late starts its slide part way through; one dated before its sample waits against the playhead")
    func slideFromTheSamplesMoment() throws {
        let view = tapeView()
        view.show(StageTape(levels: [0.5], flags: [], newest: 7, paused: false), slide: .from(Date(timeIntervalSinceNow: -0.04)), ink: ink, accent: accent)
        let late = try #require(view.tape.animation(forKey: StageBand.slideKey))
        let lateBy = view.tape.convertTime(CACurrentMediaTime(), from: nil) - late.beginTime
        view.show(StageTape(levels: [0.5, 0.5], flags: [], newest: 8, paused: false), slide: .from(Date(timeIntervalSinceNow: 0.02)), ink: ink, accent: accent)
        let early = try #require(view.tape.animation(forKey: StageBand.slideKey))
        let waits = early.beginTime - view.tape.convertTime(CACurrentMediaTime(), from: nil)

        #expect(lateBy > 0.035 && lateBy < 0.07, "40 ms late, the slide is \(lateBy) s in")
        #expect(waits > 0.01 && waits <= 0.02, "the slide begins \(waits) s from now")
        #expect(early.fillMode == .backwards)
        #expect(view.tape.affineTransform() == heldStep, "once a slide ends the bars hold a step on")
    }

    @Test("a paused or hidden band holds its bars a step on and slides nothing; under Reduce Motion they stand against the playhead")
    func heldOrStill() {
        let held = tapeView()
        held.show(StageTape(levels: [0.5], flags: [], newest: 3, paused: true), slide: .held, ink: ink, accent: accent)
        let still = tapeView()
        still.show(StageTape(levels: [0.5], flags: [], newest: 3, paused: false), slide: .still, ink: ink, accent: accent)

        #expect(held.tape.animation(forKey: StageBand.slideKey) == nil)
        #expect(held.tape.affineTransform() == heldStep)
        #expect(still.tape.animation(forKey: StageBand.slideKey) == nil)
        #expect(still.tape.affineTransform() == .identity)
    }

    @Test("the bars are built from a tape that differs from the one drawn, never again for an equal one")
    func buildsOnlyForANewSample() {
        let view = tapeView()
        view.show(StageTape(levels: [0.1, 0.2], flags: [], newest: 41, paused: false), slide: .held, ink: ink, accent: accent)
        let first = bars(view)
        view.show(StageTape(levels: [0.9, 0.9], flags: [], newest: 41, paused: false), slide: .held, ink: ink, accent: accent)
        let equal = bars(view)
        view.show(StageTape(levels: [0.9, 0.9], flags: [], newest: 42, paused: false), slide: .held, ink: ink, accent: accent)
        let next = bars(view)

        #expect(first != nil)
        #expect(equal == first, "an equal tape leaves the bars as they were")
        #expect(next != first)
    }

    @Test("a meeting's You lane sits over the Mac audio lane, inked darker at the top, and at 40 % once your microphone isn't in the take")
    func lanesAndTheLostMic() throws {
        let view = tapeView()
        view.show(StageTape(levels: [0.5], micLevels: [0.5], flags: [], newest: 0, paused: false), slide: .held, ink: ink, accent: accent)
        let you = try #require(view.lanes.first)
        let mac = try #require(view.lanes.last)
        let youRect = you.convert(you.bounds, to: view.layer)
        let macRect = mac.convert(mac.bounds, to: view.layer)
        let full = inks(you).map(\.alpha)
        let fullStrength = zip(full, [0.55, 0.55, 0.26]).allSatisfy { abs($0 - 0.85 * $1) < 0.0001 }

        #expect(view.lanes.count == 2)
        #expect(youRect.height == 70 && macRect.height == 70)
        #expect(youRect.minY > macRect.minY, "the view's layer counts up from the bottom: You is the upper lane")
        #expect(you.startPoint == CGPoint(x: 0.5, y: 0) && you.endPoint == CGPoint(x: 0.5, y: 1) && you.locations == [0, 0.5, 1])
        #expect(fullStrength, "\(full)")
        #expect(inks(mac).map(\.alpha) == full)

        view.show(StageTape(levels: [0.5], micLevels: [0.5], micLost: "Microphone stopped", flags: [], newest: 0, paused: false), slide: .held, ink: ink, accent: accent)
        let lost = inks(view.lanes.first).map(\.alpha)
        let offStrength = lost.count == 3 && zip(lost, full).allSatisfy { abs($0 - $1 * StageBand.offLaneStrength) < 0.0001 }
        #expect(offStrength, "\(lost)")
        #expect(inks(view.lanes.last).map(\.alpha) == full, "the Mac audio lane keeps its ink")
    }

    @Test("a flag stands at its marker's sample: the pole under the bars at half the accent, the pennant over them in full")
    func flagsAtTheirOffsets() throws {
        let view = tapeView()
        view.show(StageTape(levels: [Float](repeating: 0.5, count: 30), flags: [0, 19], newest: 29, paused: false), slide: .held, ink: ink, accent: accent)
        let poles = try #require(view.poles.path)
        let pennants = try #require(view.pennants.path)
        let playheadX = StageBand.playheadX(width: 1180)
        let newest = StageBand.barX(offset: 0, playheadX: playheadX) + StageBand.barWidth / 2
        let marked = StageBand.barX(offset: 19, playheadX: playheadX) + StageBand.barWidth / 2
        let unmarked = StageBand.barX(offset: 9, playheadX: playheadX) + StageBand.barWidth / 2
        let order = view.tape.sublayers ?? []
        let poleIndex = try #require(order.firstIndex(of: view.poles))
        let firstLane = view.lanes.first.flatMap { order.firstIndex(of: $0) }
        let laneIndex = try #require(firstLane)
        let pennantIndex = try #require(order.firstIndex(of: view.pennants))

        #expect(poles.contains(CGPoint(x: newest, y: 70)))
        #expect(poles.contains(CGPoint(x: marked, y: 70)))
        #expect(!poles.contains(CGPoint(x: unmarked, y: 70)), "no flag where no marker is")
        #expect(poles.contains(CGPoint(x: marked, y: 4)) && !poles.contains(CGPoint(x: marked, y: 2)), "from 3 pt under the band's top")
        #expect(poles.contains(CGPoint(x: marked, y: 131)) && !poles.contains(CGPoint(x: marked, y: 133)), "to 8 pt over its foot")
        #expect(pennants.contains(CGPoint(x: marked + 8, y: 6.5)), "the pennant points 8 pt right off the top of its pole")
        #expect(!pennants.contains(CGPoint(x: marked - 1, y: 6.5)) && !pennants.contains(CGPoint(x: marked + 10, y: 6.5)))
        #expect(!pennants.contains(CGPoint(x: marked + 3, y: 12)))
        #expect(!pennants.contains(CGPoint(x: unmarked + 3, y: 6.5)))
        #expect(sameColor(view.poles.fillColor, accent.copy(alpha: 0.5)))
        #expect(sameColor(view.pennants.fillColor, accent))
        #expect(poleIndex < laneIndex && laneIndex < pennantIndex)
    }

    @Test("a band resized, as a landing carries it into the media bar, builds its bars again for its new size, with nothing animated")
    func rebuildsOnResize() throws {
        let (hosted, view) = try hostedTapeView(StageTape(levels: [Float](repeating: 1, count: 20), flags: [], newest: 19, paused: false))
        defer { hosted.close() }
        let wide = try #require(bars(view)).boundingBoxOfPath
        view.setFrameSize(CGSize(width: 600, height: 70))
        let narrow = try #require(bars(view)).boundingBoxOfPath
        let lane = try #require(view.lanes.first)

        #expect(abs(wide.maxX - (StageBand.playheadX(width: 1180) - StageBand.gap)) < 0.01)
        #expect(abs(wide.height - 124) < 0.01, "full scale fills the band inside its 8 pt margins")
        #expect(abs(narrow.maxX - (StageBand.playheadX(width: 600) - StageBand.gap)) < 0.01)
        #expect(abs(narrow.height - 54) < 0.01)
        #expect(lane.frame == CGRect(x: 0, y: 0, width: 600, height: 70))
        #expect(view.tape.bounds.size == CGSize(width: 600, height: 70))
        #expect(lane.animationKeys() == nil && view.tape.animationKeys() == nil)
    }

    @Test("a band a landing's animation carries into the media bar builds its bars for every frame's size, and none of its layers animate on their own")
    func followsAnAnimatedResize() async throws {
        let frame = BandFrame()
        let levels = [Float](repeating: 0.6, count: 40)
        let tape = StageTape(levels: levels, micLevels: levels, flags: [3], newest: 39, paused: false)
        let hosted = HostedWindow(BandInFrame(tape: tape, frame: frame), width: 1180, height: StageBand.height)
        defer { hosted.close() }
        let found = tapeViews(in: hosted).first
        let view = try #require(found)
        let host = try #require(view.layer)
        let landed = CGSize(width: 600, height: 70)

        withAnimation(.linear(duration: 0.4)) { frame.wide = false }
        var widths: [CGFloat] = []
        var unbuilt: [CGSize] = []
        var animated: Set<String> = []
        let started = ContinuousClock.now
        while ContinuousClock.now < started + .seconds(3) {
            let size = view.frame.size
            widths.append(size.width)
            if view.tape.bounds.size != size { unbuilt.append(size) }
            for layer in [host, view.tape, view.poles, view.pennants] + view.lanes + view.lanes.compactMap(\.mask) {
                animated.formUnion(layer.animationKeys() ?? [])
            }
            if size == landed, ContinuousClock.now > started + .milliseconds(500) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let between = Set(widths.filter { $0 > landed.width && $0 < 1180 })

        #expect(between.count > 1, "the band went through \(Set(widths).sorted())")
        #expect(unbuilt.isEmpty, "bars built for another size while the band was \(unbuilt)")
        #expect(animated.isEmpty, "layers animating on their own: \(animated.sorted())")
        #expect(view.frame.size == landed)
    }

    @Test("a band already up follows its window from light to dark and back, the bars' ink and the flags' accent alike")
    func followsTheAppearance() async throws {
        let tape = StageTape(levels: [0.5, 0.9], flags: [0], newest: 1, paused: false)
        let hosted = HostedWindow(tape.drawn(.held), width: 600, height: StageBand.height)
        defer { hosted.close() }
        let view = try #require(tapeViews(in: hosted).first)
        let flips: [(NSAppearance.Name, ColorScheme)] = [(.aqua, .light), (.darkAqua, .dark), (.aqua, .light)]
        for (name, scheme) in flips {
            hosted.window.appearance = NSAppearance(named: name)
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let expectedInk = DS.Color.primaryText.resolve(in: environment).cgColor
            let expectedAccent = DS.Color.accent.resolve(in: environment).cgColor
            let followed = await waitUntil(timeoutMs: 2_000) {
                sameColor(inks(view.lanes.first).first, expectedInk.copy(alpha: expectedInk.alpha * 0.55))
                    && sameColor(view.pennants.fillColor, expectedAccent)
            }
            #expect(followed, "\(name.rawValue)")
        }
        let same = tapeViews(in: hosted).first === view
        #expect(same, "the band that was up, not one built again")
    }
}

@MainActor
@Observable
private final class BandFrame {
    var wide = true
}

/// The band at the Stage's size or the media bar's, as a landing carries it from one to the other.
private struct BandInFrame: View {
    let tape: StageTape
    let frame: BandFrame

    var body: some View {
        tape.drawn(.held)
            .frame(width: frame.wide ? 1180 : 600, height: frame.wide ? StageBand.height : 70)
    }
}

@MainActor
@Observable
private final class BandSight {
    var shown = false
}

/// The Stage's band for the model's take, in sight or out of it as the test says.
private struct BandInSight: View {
    let model: AppModel
    let sight: BandSight
    var reduceMotion = false

    var body: some View {
        Group {
            if let take = model.recording {
                StageBand(take: take, isOnScreen: sight.shown)
            }
        }
        .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage band takes", .serialized)
    struct StageBandTakeTests {
        private func host(_ model: AppModel, _ sight: BandSight, reduceMotion: Bool = false) -> HostedWindow {
            HostedWindow(BandInSight(model: model, sight: sight, reduceMotion: reduceMotion).environment(model), width: 1180, height: StageBand.height)
        }

        private func newestSample(_ model: AppModel) -> Int {
            (model.takeLevels?.sampleCount ?? 0) - 1
        }

        @Test("each of a take's levels stamps when it came in, the moment the band slides from")
        func levelsStampTheirTime() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-band-tick")
                try await startFixtureTake(model)
                let firstTick = model.takeLevelTick
                let firstStamp = model.takeLevelTickAt
                let moved = await waitUntil { model.takeLevelTick > firstTick }
                #expect(moved)
                #expect(model.takeLevelTickAt > firstStamp)
                #expect(model.takeLevelTickAt <= Date())
                await model.discardTake()
            }
        }

        @Test("out of sight or paused the band builds nothing new and slides nothing; back in sight it shows the take's bars at once")
        func restsUnlessLive() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-band-rest")
                model.selectedModel = "openai_whisper-tiny"
                try await startFixtureTake(model, seconds: 5)
                let sight = BandSight()
                let hosted = host(model, sight)
                defer { hosted.close() }
                let found = tapeViews(in: hosted).first
                let view = try #require(found)
                let hiddenBars = view.built?.newest
                let tick = model.takeLevelTick
                let movedOn = await waitUntil { model.takeLevelTick >= tick + 3 }
                #expect(movedOn)
                #expect(view.built?.newest == hiddenBars, "out of sight the band keeps the bars it had")
                #expect(view.tape.animation(forKey: StageBand.slideKey) == nil, "and slides nothing")

                sight.shown = true
                let caughtUp = await waitUntil {
                    view.built?.newest == newestSample(model) && view.tape.animation(forKey: StageBand.slideKey) != nil
                }
                #expect(caughtUp, "in sight it shows the newest sample's bars and slides from it")

                let paused = model.pauseTake()
                #expect(paused)
                let pausedBars = await waitUntil { view.built?.paused == true }
                #expect(pausedBars)
                await settle(for: .milliseconds(150))
                let heldBars = view.built?.newest
                let lastSlide = view.tape.animation(forKey: StageBand.slideKey)?.beginTime
                await settle(for: .milliseconds(400))
                #expect(view.built?.newest == heldBars)
                #expect(view.tape.animation(forKey: StageBand.slideKey)?.beginTime == lastSlide, "no slide starts while the take is paused")
                #expect(view.tape.affineTransform() == CGAffineTransform(translationX: -StageBand.step, y: 0))
                await model.discardTake()
            }
        }

        @Test("the band's layer view follows a live take's samples by itself, sliding from each, with no SwiftUI update; let go, it builds nothing more")
        func followsTheTakeAlone() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-band-follow")
                model.selectedModel = "openai_whisper-tiny"
                try await startFixtureTake(model, seconds: 5)
                let view = StageBand.TapeView()
                let window = OffscreenWindow(width: 1180, height: StageBand.height, styleMask: [.borderless])
                window.contentView = view
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                let feed = TapeFeed(model: model, cadence: .glides, markers: [], micState: nil, macStopped: false)
                view.follow(feed, ink: CGColor(gray: 0, alpha: 0.85), accent: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
                let first = view.built?.newest ?? -1
                let followed = await waitUntil {
                    (view.built?.newest ?? -1) >= first + 3 && view.built?.newest == newestSample(model)
                        && view.tape.animation(forKey: StageBand.slideKey) != nil
                }
                #expect(followed, "the bars keep up with the take and slide from its newest sample")

                view.stopFollowing()
                let lastBars = view.built?.newest
                let tick = model.takeLevelTick
                let movedOn = await waitUntil { model.takeLevelTick >= tick + 3 }
                #expect(movedOn)
                #expect(view.built?.newest == lastBars, "let go, the band keeps the bars it had")
                await model.discardTake()
            }
        }

        @Test("under Reduce Motion the band follows the take at most four times a second and never slides")
        func reduceMotionSteps() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-band-steps")
                model.selectedModel = "openai_whisper-tiny"
                try await startFixtureTake(model, seconds: 5)
                let sight = BandSight()
                sight.shown = true
                let hosted = host(model, sight, reduceMotion: true)
                defer { hosted.close() }
                let found = tapeViews(in: hosted).first
                let view = try #require(found)
                let first = view.built?.newest ?? -1
                let followed = await waitUntil { (view.built?.newest ?? -1) >= first + 3 }
                #expect(followed, "the bars keep up with the take")

                var seen: Set<Int> = []
                let watchUntil = ContinuousClock.now + .seconds(1)
                while ContinuousClock.now < watchUntil {
                    if let newest = view.built?.newest { seen.insert(newest) }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(seen.count <= 5, "the bars were built \(seen.count) times in a second")
                #expect(view.tape.animation(forKey: StageBand.slideKey) == nil)
                #expect(view.tape.affineTransform() == .identity, "the newest bar stands against the playhead")
                await model.discardTake()
            }
        }
    }
}

/// A capture whose level the test sets.
private actor BandLevelCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL

    init(file: URL) { self.file = file }

    func start() async throws {}
    func prepare() async throws -> URL { file }
    func cancel() async {}
}

@MainActor
@Suite("Stage band under VoiceOver", .serialized)
struct StageBandVoiceOverTests {
    private func spokenLevel(in hosted: HostedWindow) -> String? {
        HostedAccessibility.elements(in: hosted.host).first { $0.label == "Input level" }?.value
    }

    @Test("with VoiceOver running the band says each new level as it comes in, while its layer view draws the bars")
    func saysEachLevel() async throws {
        let audio = try tempWAV("band-voiceover")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("band-voiceover")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.voiceOverIsRunning = true
        let capture = BandLevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { await model.discardTake() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)

        let sight = BandSight()
        sight.shown = true
        let hosted = HostedWindow(BandInSight(model: model, sight: sight).environment(model), width: 1180, height: StageBand.height)
        defer { hosted.close() }
        let drawn = await waitUntil { spokenLevel(in: hosted) != nil }
        try #require(drawn)

        let loud = Task { @MainActor in
            while !Task.isCancelled {
                capture.levelMeter.record(0.8)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { loud.cancel() }
        let said = await waitUntil { spokenLevel(in: hosted) == AppFormat.percent(0.8) }
        #expect(said, "the band still says \(spokenLevel(in: hosted) ?? "nothing")")
    }

    @Test("with VoiceOver off the stand-in holds its first level while the band's layer view keeps following")
    func holdsItsFirstLevelWithoutVoiceOver() async throws {
        let audio = try tempWAV("band-no-voiceover")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("band-no-voiceover")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.voiceOverIsRunning = false
        let capture = BandLevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { await model.discardTake() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)

        let sight = BandSight()
        sight.shown = true
        let hosted = HostedWindow(BandInSight(model: model, sight: sight).environment(model), width: 1180, height: StageBand.height)
        defer { hosted.close() }
        let drawn = await waitUntil { spokenLevel(in: hosted) != nil }
        try #require(drawn)
        let first = spokenLevel(in: hosted)

        let tick = model.takeLevelTick
        let loud = Task { @MainActor in
            while !Task.isCancelled {
                capture.levelMeter.record(0.8)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { loud.cancel() }
        let movedOn = await waitUntil { model.takeLevelTick >= tick + 3 }
        #expect(movedOn)
        let held = spokenLevel(in: hosted)
        #expect(held == first, "the stand-in followed a tick SwiftUI never reads: \(held ?? "nothing")")
    }
}
