import Foundation
import Testing
@testable import Parola

@Suite("LevelHistory")
struct LevelHistoryTests {
    @Test("init fills with zeros to capacity")
    func initFilledWithZeros() {
        let history = LevelHistory(capacity: 8)
        #expect(history.samples.count == 8)
        #expect(history.samples.allSatisfy { $0 == 0 })
    }

    @Test("append rotates FIFO")
    func appendRotatesFifo() {
        var history = LevelHistory(capacity: 4)
        history.append(0.1)
        history.append(0.2)
        history.append(0.3)
        #expect(history.samples == [0, 0.1, 0.2, 0.3])
        history.append(0.4)
        history.append(0.5)
        #expect(history.samples == [0.2, 0.3, 0.4, 0.5])
    }

    @Test("append clamps negative values to zero")
    func clampsBelowZero() {
        var history = LevelHistory(capacity: 3)
        history.append(-0.5)
        #expect(history.samples.last == 0)
    }

    @Test("append clamps values above one to one")
    func clampsAboveOne() {
        var history = LevelHistory(capacity: 3)
        history.append(1.7)
        #expect(history.samples.last == 1)
    }

    @Test("zero or negative capacity falls back to a single slot")
    func capacityZeroIsSane() {
        let history = LevelHistory(capacity: 0)
        #expect(history.samples.count == 1)
        var mutable = history
        mutable.append(0.5)
        #expect(mutable.samples == [0.5])
    }
}
