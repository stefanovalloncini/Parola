import Testing
@testable import Parola

@MainActor
@Suite("Take level history")
struct TakeLevelHistoryTests {
    @Test("recent levels come back newest last, padded with silence at the front")
    func recent() {
        let history = TakeLevelHistory(recentSeconds: 1)
        history.append(0.1)
        history.append(0.2)
        #expect(history.recent(4) == [0, 0, 0.1, 0.2])
    }

    @Test("the recent window keeps only its last seconds")
    func recentIsBounded() {
        let history = TakeLevelHistory(recentSeconds: 1)
        for i in 0..<25 { history.append(Float(i) / 100) }
        #expect(history.recent(10).last == 0.24)
        #expect(history.recent(10).first == 0.15)
    }

    @Test("a ten-hour take stays within the overview's capacity and still covers the whole take")
    func overviewIsBounded() {
        let history = TakeLevelHistory(recentSeconds: 30, overviewCapacity: 36_000)
        for _ in 0..<(10 * 3600 * 10) { history.append(0.5) }
        #expect(history.overview.count <= 36_000)
        #expect(history.sampleCount == 360_000)
        #expect(Double(history.overview.count) * history.secondsPerOverviewSample >= 10 * 3600 - 1)
    }

    @Test("pooling keeps each stretch's loudest moment")
    func pooling() {
        let history = TakeLevelHistory(recentSeconds: 1)
        for level: Float in [0.1, 0.9, 0.2, 0.3] { history.append(level) }
        #expect(history.pooled(into: 2) == [0.9, 0.3])
    }
}
