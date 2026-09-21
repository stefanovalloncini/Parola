import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics translation")
struct StatisticsLocalizationTests {
    private let italian = Locale(identifier: "it_IT")

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the inspector row and the speed it carries read in Italian")
    func inspectorRowInItalian() throws {
        let bundle = try italianBundle()

        #expect(String(localized: "Transcribed in", bundle: bundle) == "Trascritto in")
        #expect(StatisticsCopy.speed(16, bundle: bundle, locale: italian) == "16×\u{00A0}tempo reale")
        #expect(
            StatisticsCopy.transcribedIn(seconds: 37, audioSeconds: 592, bundle: bundle, locale: italian)
                == "\(AppFormat.duration(seconds: 37, locale: italian)) · 16×\u{00A0}tempo reale"
        )
    }

    @Test("the tiles and the sections are named in Italian")
    func pageChromeInItalian() throws {
        let bundle = try italianBundle()
        let pairs = [
            ("Statistics", "Statistiche"),
            ("Transcripts", "Trascrizioni"),
            ("Audio transcribed", "Audio trascritto"),
            ("Time transcribing", "Tempo di trascrizione"),
            ("Average speed", "Velocità media"),
            ("Words", "Parole"),
            ("Records", "Record"),
            ("Longest transcript", "Trascrizione più lunga"),
            ("Longest run", "Esecuzione più lunga"),
            ("Fastest run", "Esecuzione più veloce"),
            ("no word counts yet", "nessun conteggio parole"),
            ("By Model", "Per modello"),
            ("By Kind", "Per tipo"),
            ("Activity", "Attività"),
            ("30 Days", "30 giorni"),
            ("12 Months", "12 mesi"),
            ("Nothing transcribed in the last 12 months", "Nessuna trascrizione negli ultimi 12 mesi"),
            ("Nothing transcribed", "Nessuna trascrizione"),
            ("min", "min"),
            ("h", "h"),
            ("Runs", "Esecuzioni"),
            ("Speed", "Velocità"),
            ("No Statistics Yet", "Ancora nessuna statistica"),
        ]
        for (key, expected) in pairs {
            #expect(String(localized: String.LocalizationValue(key), bundle: bundle) == expected, "\(key)")
        }
    }

    /// The interpolated keys are the ones that break silently: a changed template falls back to English.
    @Test("the interpolated lines resolve against the Italian templates")
    func interpolatedLinesInItalian() throws {
        let bundle = try italianBundle()
        let audio = AppFormat.duration(seconds: 4_800, locale: italian)

        #expect(
            StatisticsCopy.subtitle(entries: 12, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "12 trascrizioni · \(audio) trascritti"
        )
        #expect(
            StatisticsCopy.subtitle(entries: 1, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "1 trascrizione · \(audio) trascritti"
        )
        #expect(
            StatisticsCopy.activity(range: .days30, entries: 4, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "4 trascrizioni · \(audio) di audio"
        )
        #expect(
            StatisticsCopy.activity(range: .days30, entries: 0, audioSeconds: 0, bundle: bundle, locale: italian)
                == "Nessuna trascrizione negli ultimi 30 giorni"
        )
        #expect(
            StatisticsCopy.activity(range: .months12, entries: 0, audioSeconds: 0, bundle: bundle, locale: italian)
                == "Nessuna trascrizione negli ultimi 12 mesi"
        )
        #expect(
            StatisticsCopy.bucket(label: "18 set", entries: 0, audioSeconds: 0, bundle: bundle, locale: italian)
                == "18 set · Nessuna trascrizione"
        )
        #expect(
            StatisticsCopy.bucket(label: "18 set", entries: 4, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "18 set · 4 trascrizioni · \(audio)"
        )
    }

    @Test("the chart's axis units read in Italian with the locale's decimal separator")
    func axisUnitsInItalian() throws {
        let bundle = try italianBundle()
        let hours = ActivityAxis(maxMinutes: 200)
        #expect(hours.label(90, bundle: bundle, locale: italian) == "1,5 h")
        #expect(ActivityAxis(maxMinutes: 45).label(30, bundle: bundle, locale: italian) == "30 min")
    }

    @Test("the coverage note reads in Italian in each of its three forms")
    func coverageNoteInItalian() throws {
        let bundle = try italianBundle()
        let day = Date(timeIntervalSince1970: 1_757_635_200)
        let dayLabel = AppFormat.day(day, locale: italian)

        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 4, total: 27, since: day),
                wordsCountedFor: 27, entries: 27, bundle: bundle, locale: italian
            ) == "Tempi registrati dal \(dayLabel) · 4 / 27 trascrizioni"
        )
        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 3, total: 3, since: day),
                wordsCountedFor: 3, entries: 3, bundle: bundle, locale: italian
            ) == "Tempi registrati per ogni trascrizione."
        )
        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 0, total: 9, since: nil),
                wordsCountedFor: 9, entries: 9, bundle: bundle, locale: italian
            ) == "Nessun tempo registrato finora: le nuove trascrizioni misurano quanto impiegano."
        )
    }

    @Test("the word-count suffixes read in Italian")
    func wordCoverageInItalian() throws {
        let bundle = try italianBundle()
        let day = Date(timeIntervalSince1970: 1_757_635_200)
        let all = LibraryStatistics.Coverage(count: 3, total: 3, since: day)
        #expect(
            StatisticsCopy.coverage(all, wordsCountedFor: 2, entries: 3, bundle: bundle, locale: italian)
                == "Tempi registrati per ogni trascrizione · parole contate per 2 / 3"
        )
        #expect(
            StatisticsCopy.coverage(all, wordsCountedFor: 0, entries: 3, bundle: bundle, locale: italian)
                == "Tempi registrati per ogni trascrizione · nessun conteggio parole"
        )
    }
}
