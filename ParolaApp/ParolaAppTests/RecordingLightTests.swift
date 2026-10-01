import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

/// The lights a hosted view put up, as AppKit holds them.
@MainActor
private func lights(in hosted: HostedWindow) -> [RecDot.LightView] {
    func lights(in view: NSView) -> [RecDot.LightView] {
        ((view as? RecDot.LightView).map { [$0] } ?? []) + view.subviews.flatMap(lights(in:))
    }
    hosted.host.layoutSubtreeIfNeeded()
    return lights(in: hosted.host)
}

@MainActor
private func pulsingLights(in hosted: HostedWindow) -> Int {
    lights(in: hosted).filter { $0.dot.animation(forKey: RecDot.pulseKey) != nil }.count
}

/// How far into its one-second loop a light's pulse is right now.
@MainActor
private func loopPosition(_ light: RecDot.LightView) -> Double? {
    guard let pulse = light.dot.animation(forKey: RecDot.pulseKey) else { return nil }
    let now = light.dot.convertTime(CACurrentMediaTime(), from: nil)
    return (now - pulse.beginTime).truncatingRemainder(dividingBy: 1)
}

/// A click as AppKit delivers one: the press goes to the window at the view's centre, its release already waiting in the queue.
@MainActor
private func click(_ view: NSView) {
    guard let window = view.window else { return }
    let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    func event(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }
    guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
    NSApp.postEvent(up, atStart: false)
    window.sendEvent(down)
}

/// How far into its current second the take is right now.
private func takeSecond(since origin: Date) -> Double {
    Date().timeIntervalSince(origin).truncatingRemainder(dividingBy: 1)
}

/// The distance between two moments of a one-second loop, either way round.
private func loopGap(_ a: Double, _ b: Double) -> Double {
    let gap = abs(a - b).truncatingRemainder(dividingBy: 1)
    return min(gap, 1 - gap)
}

@Suite("Recording light")
struct RecordingLightTests {
    @MainActor
    @Test("the render server loops one second of the light's curve, full as the second turns and 35 % halfway, at about 30 frames a second")
    func pulseCurve() {
        let pulse = RecDot.pulseAnimation(beginTime: 0)
        let values = pulse.values as? [Double] ?? []
        let times = pulse.keyTimes?.map(\.doubleValue) ?? []
        let offCurve = zip(times, values).filter { abs(RecDot.pulse(at: $0) - $1) > 0.0001 }
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.duration == 1)
        #expect(pulse.repeatCount == .infinity)
        #expect(pulse.preferredFrameRateRange == CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30))
        #expect(values.count == times.count)
        #expect(values.count > 30)
        #expect(times.first == 0)
        #expect(times.last == 1)
        #expect(values.first == 1)
        #expect(values.last == 1)
        #expect(abs((values.min() ?? 0) - 0.35) < 0.0001)
        #expect(offCurve.isEmpty)
    }

    @Test("the loop begins where the take's current second began, however far into the take the light is built")
    func pulseBegin() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(RecDot.pulseBegin(origin: origin, now: origin.addingTimeInterval(12.25), layerTime: 100) == 99.75)
        #expect(RecDot.pulseBegin(origin: origin, now: origin.addingTimeInterval(12), layerTime: 100) == 100)
        let threeHours = RecDot.pulseBegin(origin: origin, now: origin.addingTimeInterval(3 * 3600 + 0.5), layerTime: 100)
        #expect(abs(threeHours - 99.5) < 0.000_001)
    }

    @MainActor
    @Test("a light built mid-take pulses in step with the take's seconds, and one built later joins the same beat")
    func pulseLocksToTheTake() async throws {
        let origin = Date(timeIntervalSinceNow: -12.25)
        let first = HostedWindow(RecDot(pulsesFrom: origin), width: 40, height: 40)
        defer { first.close() }
        let light = try #require(lights(in: first).first)
        let position = try #require(loopPosition(light))
        let expected = takeSecond(since: origin)
        #expect(loopGap(position, expected) < 0.03, "the loop is \(position) s in, the take's second \(expected) s")

        await settle(for: .milliseconds(350))
        let second = HostedWindow(RecDot(pulsesFrom: origin), width: 40, height: 40)
        defer { second.close() }
        let rebuilt = try #require(lights(in: second).first)
        let firstBegin = try #require(light.dot.animation(forKey: RecDot.pulseKey)?.beginTime)
        let secondBegin = try #require(rebuilt.dot.animation(forKey: RecDot.pulseKey)?.beginTime)
        #expect(loopGap(firstBegin, secondBegin) < 0.01, "a light built 0.35 s later starts its loop on the same whole seconds")
    }

    @MainActor
    @Test("after the Mac wakes, a light whose loop slipped while it slept pulses in step with the take again")
    func wakeBringsTheLoopBack() async throws {
        let origin = Date(timeIntervalSinceNow: -12.25)
        let hosted = HostedWindow(RecDot(pulsesFrom: origin), width: 40, height: 40)
        defer { hosted.close() }
        let light = try #require(lights(in: hosted).first)
        let layerNow = light.dot.convertTime(CACurrentMediaTime(), from: nil)
        let inStep = RecDot.pulseBegin(origin: origin, now: Date(), layerTime: layerNow)
        light.dot.add(RecDot.pulseAnimation(beginTime: inStep - 0.5), forKey: RecDot.pulseKey)
        let slipped = try #require(loopPosition(light))
        #expect(loopGap(slipped, takeSecond(since: origin)) > 0.4, "half a second out, as after a sleep")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        let back = await waitUntil(timeoutMs: 2_000) {
            loopPosition(light).map { loopGap($0, takeSecond(since: origin)) < 0.03 } ?? false
        }
        #expect(back)
    }

    @MainActor
    @Test("the light is an 8 pt disc of the recording red in either appearance, and clicks pass through it to its button")
    func lightShape() throws {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let reds: [(ColorScheme, RGBA)] = [(.light, RGBA(0.769, 0.137, 0.165)), (.dark, RGBA(0.839, 0.208, 0.184))]
        for (scheme, red) in reds {
            let hosted = HostedWindow(RecDot(pulsesFrom: Date()).environment(\.colorScheme, scheme), width: 40, height: 40)
            defer { hosted.close() }
            let light = try #require(lights(in: hosted).first)
            let fill = light.dot.backgroundColor?.converted(to: sRGB, intent: .defaultIntent, options: nil)
            let rgb = fill?.components ?? []
            #expect(rgb.count == 4)
            #expect(abs((rgb.first ?? 0) - red.r) < 0.01 && abs((rgb.dropFirst().first ?? 0) - red.g) < 0.01, "\(scheme): \(rgb)")
            #expect(light.dot.frame.size == CGSize(width: 8, height: 8))
            #expect(light.dot.cornerRadius == 4)
            #expect(light.hitTest(NSPoint(x: 4, y: 4)) == nil)
        }
    }

    @MainActor
    @Test("a light already up follows its window from light to dark and back")
    func lightFollowsTheAppearance() async throws {
        let hosted = HostedWindow(RecDot(pulsesFrom: Date()), width: 40, height: 40)
        defer { hosted.close() }
        let light = try #require(lights(in: hosted).first)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func red() -> Double {
            Double(light.dot.backgroundColor?.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components?.first ?? 0)
        }
        let flips: [(NSAppearance.Name, Double)] = [(.aqua, 0.769), (.darkAqua, 0.839), (.aqua, 0.769)]
        for (name, expected) in flips {
            hosted.window.appearance = NSAppearance(named: name)
            let followed = await waitUntil(timeoutMs: 2_000) { abs(red() - expected) < 0.01 }
            #expect(followed, "\(name.rawValue): red \(red())")
        }
        let same = lights(in: hosted).first === light
        #expect(same, "the light that was up, not one built again")
    }

    @MainActor
    @Test("under Reduce Motion, or with nothing to pulse from, the light holds still at full strength")
    func stillUnderReduceMotion() {
        let origin = Date(timeIntervalSinceNow: -5)
        let reduced = HostedWindow(RecDot(pulsesFrom: origin).environment(\._accessibilityReduceMotion, true), width: 40, height: 40)
        defer { reduced.close() }
        let idle = HostedWindow(RecDot(pulsesFrom: nil), width: 40, height: 40)
        defer { idle.close() }
        let moving = HostedWindow(RecDot(pulsesFrom: origin), width: 40, height: 40)
        defer { moving.close() }
        #expect(lights(in: reduced).isEmpty)
        #expect(lights(in: idle).isEmpty)
        #expect(pulsingLights(in: moving) == 1)
    }
}

@MainActor
@Suite("Recording light on the take's surfaces", .serialized)
struct RecordingLightSurfaceTests {
    private func stage(_ take: RecordingSession, _ model: AppModel, onScreen: Bool) -> HostedWindow {
        HostedWindow(StageFacts(take: take, isOnScreen: onScreen).environment(model), width: 700, height: 80)
    }

    private func capsule(_ take: RecordingSession, onScreen: Bool) -> HostedWindow {
        let face = SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: onScreen, showStage: {}, stop: { _ in })
        return HostedWindow(face, width: 400, height: 80)
    }

    private func pill(_ model: AppModel, onScreen: Bool) -> HostedWindow {
        let face = RecordingPillFace(model: model, isOnScreen: onScreen, onShowParola: {}, onStop: {}, onSize: { _ in })
        return HostedWindow(face, width: 400, height: 80)
    }

    /// The Stage's, the capsule's and the pill's lights that pulse for the model's take as it stands.
    private func pulsing(_ model: AppModel, onScreen: Bool = true) throws -> [Int] {
        let take = try #require(model.recording)
        let surfaces = [stage(take, model, onScreen: onScreen), capsule(take, onScreen: onScreen), pill(model, onScreen: onScreen)]
        defer { surfaces.forEach { $0.close() } }
        return surfaces.map(pulsingLights(in:))
    }

    @Test("the Stage, the capsule and the pill pulse while the take records; paused or finishing every light holds still")
    func stillWhilePausedOrFinishing() throws {
        let audio = try tempWAV("light-surfaces")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("light-surfaces")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -30))
        defer { model.endTestTake() }
        let takeID = model.recording?.takeID

        let recording = try pulsing(model)
        let covered = try pulsing(model, onScreen: false)
        model.updateSession(of: takeID) { $0.pause(at: Date()) }
        let paused = try pulsing(model)
        model.updateSession(of: takeID) { $0.finish(at: Date()) }
        let finishing = try pulsing(model)

        #expect(recording == [1, 1, 1])
        #expect(covered == [0, 0, 0], "every light rests while its window is out of sight")
        #expect(model.recording?.state == .finishing)
        #expect(paused == [0, 0, 0])
        #expect(finishing == [0, 0, 0])
    }

    @Test("a click on the light reaches the button it sits in, once, on the capsule and on the pill")
    func clickOnTheLight() async throws {
        let audio = try tempWAV("light-click")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("light-click")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -30))
        defer { model.endTestTake() }
        let take = try #require(model.recording)
        var stageShown = 0
        var parolaShown = 0
        let capsuleFace = SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: true, showStage: { stageShown += 1 }, stop: { _ in })
        let capsule = HostedWindow(capsuleFace, width: 400, height: 80)
        defer { capsule.close() }
        let pillFace = RecordingPillFace(model: model, isOnScreen: true, onShowParola: { parolaShown += 1 }, onStop: {}, onSize: { _ in })
        let pill = HostedWindow(pillFace, width: 400, height: 80)
        defer { pill.close() }

        click(try #require(lights(in: capsule).first))
        await settle(for: .milliseconds(250))
        click(try #require(lights(in: pill).first))
        await settle(for: .milliseconds(250))

        #expect(stageShown == 1)
        #expect(parolaShown == 1)
    }
}
