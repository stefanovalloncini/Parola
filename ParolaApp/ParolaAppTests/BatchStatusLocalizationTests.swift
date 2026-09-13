import Foundation
import Testing
@testable import Parola

@Suite("Batch status translation")
struct BatchStatusLocalizationTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// Routing the percent through AppFormat makes it a String, so the catalog key moved from
    /// "Transcribing %lld%%" to "Transcribing · %@" — and a key with no Italian value falls back silently.
    @Test("the transcribing status resolves in Italian under the key the code now asks for")
    func transcribingStatusKeepsItsTranslation() throws {
        let percent = AppFormat.percent(0.45, locale: Locale(identifier: "it_IT"))
        let status = String(localized: "Transcribing · \(percent)", bundle: try italianBundle())
        #expect(status == "Trascrizione · 45%")
    }

    /// The status line reads "Completato · 12 segmenti" or it is half in English.
    @Test("a finished job counts its segments in Italian too")
    func completedStatusCountsInItalian() throws {
        let bundle = try italianBundle()
        let segments = String(localized: "\(12) segments", bundle: bundle)
        #expect(segments == "12 segmenti")
        #expect(String(localized: "1 segment", bundle: bundle) == "1 segmento")
        #expect(String(localized: "Completed · \(segments)", bundle: bundle) == "Completato · 12 segmenti")
    }
}
