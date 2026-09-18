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
        #expect(StatisticsCopy.speed(16, bundle: bundle, locale: italian) == "16× tempo reale")
        #expect(
            StatisticsCopy.transcribedIn(seconds: 37, audioSeconds: 592, bundle: bundle, locale: italian)
                == "37 s · 16× tempo reale"
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
            ("By Model", "Per modello"),
            ("By Kind", "Per tipo"),
            ("Last 30 Days", "Ultimi 30 giorni"),
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
        let audio = try #require(AppFormat.duration(seconds: 4_800, locale: italian))

        #expect(
            StatisticsCopy.subtitle(entries: 12, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "12 trascrizioni · \(audio) di audio"
        )
        #expect(
            StatisticsCopy.subtitle(entries: 1, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "1 trascrizione · \(audio) di audio"
        )
        #expect(
            StatisticsCopy.last30Days(entries: 4, audioSeconds: 4_800, bundle: bundle, locale: italian)
                == "4 trascrizioni · \(audio) di audio"
        )
        #expect(
            StatisticsCopy.last30Days(entries: 0, audioSeconds: 0, bundle: bundle, locale: italian)
                == "Niente trascritto negli ultimi 30 giorni"
        )
    }

    @Test("the coverage note reads in Italian in each of its three forms")
    func coverageNoteInItalian() throws {
        let bundle = try italianBundle()
        let day = Date(timeIntervalSince1970: 1_757_635_200)
        let dayLabel = AppFormat.day(day, locale: italian)

        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 4, total: 27, since: day), bundle: bundle, locale: italian
            ) == "Tempi registrati dal \(dayLabel) · 4 / 27 trascrizioni"
        )
        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 3, total: 3, since: day), bundle: bundle, locale: italian
            ) == "Tempi registrati per ogni trascrizione."
        )
        #expect(
            StatisticsCopy.coverage(
                LibraryStatistics.Coverage(count: 0, total: 9, since: nil), bundle: bundle, locale: italian
            ) == "Nessun tempo registrato finora: le nuove trascrizioni misurano quanto impiegano."
        )
    }
}
