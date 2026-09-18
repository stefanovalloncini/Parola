import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics page copy")
struct StatisticsPageCopyTests {
    private let english = Locale(identifier: "en_US")
    private let day = Date(timeIntervalSince1970: 1_757_635_200)

    @Test("the subtitle counts the transcripts and the audio behind them")
    func subtitleCountsTranscriptsAndAudio() {
        #expect(
            StatisticsCopy.subtitle(entries: 12, audioSeconds: 4_800, locale: english)
                == "12 transcripts · 1 hr, 20 min transcribed"
        )
        #expect(StatisticsCopy.subtitle(entries: 1, audioSeconds: 40, locale: english) == "1 transcript · 40 sec transcribed")
        #expect(StatisticsCopy.subtitle(entries: 0, audioSeconds: 0, locale: english) == "0 transcripts · 0 s transcribed")
    }

    @Test("the coverage note says when timing started and how much of the library it covers")
    func coverageNamesTheGap() {
        let partial = LibraryStatistics.Coverage(count: 4, total: 27, since: day)
        #expect(StatisticsCopy.coverage(partial, locale: english).hasPrefix("Timing recorded since "))
        #expect(StatisticsCopy.coverage(partial, locale: english).hasSuffix(" · 4 / 27 transcripts"))
    }

    @Test("a fully timed library says so, and an untimed one says what will happen")
    func coverageEdges() {
        let all = LibraryStatistics.Coverage(count: 3, total: 3, since: day)
        #expect(StatisticsCopy.coverage(all, locale: english) == "Timing recorded for every transcript.")

        let none = LibraryStatistics.Coverage(count: 0, total: 9, since: nil)
        #expect(
            StatisticsCopy.coverage(none, locale: english)
                == "No run has been timed yet — new transcriptions record how long they take."
        )
    }

    @Test("the last thirty days line counts entries and audio, or says there were none")
    func lastThirtyDaysLine() {
        #expect(StatisticsCopy.last30Days(entries: 0, audioSeconds: 0, locale: english) == "Nothing transcribed in the last 30 days")
        #expect(StatisticsCopy.last30Days(entries: 1, audioSeconds: 600, locale: english) == "1 transcript · 10 min of audio")
        #expect(StatisticsCopy.last30Days(entries: 4, audioSeconds: 4_800, locale: english) == "4 transcripts · 1 hr, 20 min of audio")
    }
}
