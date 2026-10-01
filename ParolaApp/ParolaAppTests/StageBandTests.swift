import Foundation
import Testing
@testable import Parola
import ParolaCore

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
