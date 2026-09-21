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
        #expect(StatisticsCopy.subtitle(entries: 0, audioSeconds: 0, locale: english) == "0 transcripts · 0 sec transcribed")
    }

    @Test("the coverage note says when timing started and how much of the library it covers")
    func coverageNamesTheGap() {
        let partial = LibraryStatistics.Coverage(count: 4, total: 27, since: day)
        let note = StatisticsCopy.coverage(partial, wordsCountedFor: 27, entries: 27, locale: english)
        #expect(note.hasPrefix("Timing recorded since "))
        #expect(note.hasSuffix(" · 4 / 27 transcripts"))
    }

    @Test("a fully timed library says so, and an untimed one says what will happen")
    func coverageEdges() {
        let all = LibraryStatistics.Coverage(count: 3, total: 3, since: day)
        #expect(StatisticsCopy.coverage(all, wordsCountedFor: 3, entries: 3, locale: english) == "Timing recorded for every transcript.")

        let none = LibraryStatistics.Coverage(count: 0, total: 9, since: nil)
        #expect(
            StatisticsCopy.coverage(none, wordsCountedFor: 9, entries: 9, locale: english)
                == "No run has been timed yet — new transcriptions record how long they take."
        )
    }

    @Test("the coverage note names the word count's gap, or that there is no count yet")
    func coverageNamesTheWordGap() {
        let all = LibraryStatistics.Coverage(count: 3, total: 3, since: day)
        #expect(
            StatisticsCopy.coverage(all, wordsCountedFor: 2, entries: 3, locale: english)
                == "Timing recorded for every transcript · Words counted for 2 / 3"
        )
        #expect(
            StatisticsCopy.coverage(all, wordsCountedFor: 0, entries: 3, locale: english)
                == "Timing recorded for every transcript · No word counts yet"
        )
        let partial = LibraryStatistics.Coverage(count: 4, total: 27, since: day)
        #expect(
            StatisticsCopy.coverage(partial, wordsCountedFor: 20, entries: 27, locale: english)
                .hasSuffix(" · 4 / 27 transcripts · Words counted for 20 / 27")
        )
    }

    @Test("the activity caption counts entries and audio in either range, or says there were none")
    func activityCaption() {
        #expect(StatisticsCopy.activity(range: .days30, entries: 0, audioSeconds: 0, locale: english) == "Nothing transcribed in the last 30 days")
        #expect(StatisticsCopy.activity(range: .months12, entries: 0, audioSeconds: 0, locale: english) == "Nothing transcribed in the last 12 months")
        #expect(StatisticsCopy.activity(range: .days30, entries: 1, audioSeconds: 600, locale: english) == "1 transcript · 10 min of audio")
        #expect(StatisticsCopy.activity(range: .months12, entries: 4, audioSeconds: 4_800, locale: english) == "4 transcripts · 1 hr, 20 min of audio")
    }

    @Test("the hover card names the bucket, its count and its audio, or says the bucket is empty")
    func hoverCard() {
        #expect(StatisticsCopy.bucket(label: "18 Sep", entries: 0, audioSeconds: 0, locale: english) == "18 Sep · Nothing transcribed")
        #expect(StatisticsCopy.bucket(label: "18 Sep", entries: 1, audioSeconds: 600, locale: english) == "18 Sep · 1 transcript · 10 min")
        #expect(StatisticsCopy.bucket(label: "Sep 2026", entries: 3, audioSeconds: 4_800, locale: english) == "Sep 2026 · 3 transcripts · 1 hr, 20 min")
    }
}
