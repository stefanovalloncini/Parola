import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics copy")
struct StatisticsCopyTests {
    private let english = Locale(identifier: "en_US")

    @Test("a speed is always a multiple of real time, never a bare ratio")
    func speedReadsAsAMultiple() {
        #expect(StatisticsCopy.speed(16, locale: english) == "16×\u{00A0}real time")
        #expect(StatisticsCopy.speed(1.24, locale: english) == "1.2×\u{00A0}real time")
        #expect(StatisticsCopy.speed(nil, locale: english) == nil)
    }

    @Test("the inspector's value pairs the wall time with the speed")
    func transcribedInPairsTimeAndSpeed() {
        #expect(
            StatisticsCopy.transcribedIn(seconds: 37, audioSeconds: 592, locale: english)
                == "37 sec · 16×\u{00A0}real time"
        )
        #expect(
            StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: 600, locale: english)
                == "2 min, 5 sec · 4.8×\u{00A0}real time"
        )
    }

    @Test("without a media duration the value is just the wall time")
    func transcribedInWithoutAudio() {
        #expect(StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: nil, locale: english) == "2 min, 5 sec")
        #expect(StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: 0, locale: english) == "2 min, 5 sec")
    }
}
