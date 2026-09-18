import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics copy")
struct StatisticsCopyTests {
    private let english = Locale(identifier: "en_US")

    @Test("a run under a minute reads in seconds, a longer one in minutes and seconds")
    func runDurationForm() {
        #expect(AppFormat.runDuration(seconds: 0, locale: english) == "0 s")
        #expect(AppFormat.runDuration(seconds: 0.48, locale: english) == "<1 s")
        #expect(AppFormat.runDuration(seconds: -4, locale: english) == "0 s")
        #expect(AppFormat.runDuration(seconds: 37.4, locale: english) == "37 s")
        #expect(AppFormat.runDuration(seconds: 59.6, locale: english) == "1 min 00 s")
        #expect(AppFormat.runDuration(seconds: 125, locale: english) == "2 min 05 s")
        #expect(AppFormat.runDuration(seconds: 3_600, locale: english) == "60 min 00 s")
    }

    @Test("a speed is always a multiple of real time, never a bare ratio")
    func speedReadsAsAMultiple() {
        #expect(StatisticsCopy.speed(16, locale: english) == "16× real time")
        #expect(StatisticsCopy.speed(1.24, locale: english) == "1.2× real time")
        #expect(StatisticsCopy.speed(nil, locale: english) == nil)
    }

    @Test("the inspector's value pairs the wall time with the speed")
    func transcribedInPairsTimeAndSpeed() {
        #expect(
            StatisticsCopy.transcribedIn(seconds: 37, audioSeconds: 592, locale: english)
                == "37 s · 16× real time"
        )
        #expect(
            StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: 600, locale: english)
                == "2 min 05 s · 4.8× real time"
        )
    }

    @Test("without a media duration the value is just the wall time")
    func transcribedInWithoutAudio() {
        #expect(StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: nil, locale: english) == "2 min 05 s")
        #expect(StatisticsCopy.transcribedIn(seconds: 125, audioSeconds: 0, locale: english) == "2 min 05 s")
    }
}
