import Foundation
import Testing
@testable import Parola

@Suite("Sheet translation")
struct SheetLocalizationTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the Burn sheet, an empty prompt output and the prompt editor read in Italian")
    func sheetsReadInItalian() throws {
        let bundle = try italianBundle()
        let pairs = [
            ("Burn subtitles into video", "Imprimi i sottotitoli nel video"),
            ("Captions are rendered permanently into a copy of the video.", "I sottotitoli vengono impressi in modo permanente in una copia del video."),
            ("Font size", "Dimensione font"),
            ("Text color", "Colore del testo"),
            ("White", "Bianco"),
            ("Yellow", "Giallo"),
            ("Choose Video…", "Scegli video…"),
            ("No Output", "Nessuna risposta"),
            ("The model didn't return any text.", "Il modello non ha restituito alcun testo."),
            ("Parola sends these instructions to the model along with the text.", "Parola invia queste istruzioni al modello insieme al testo."),
            ("Built-in prompts are read-only. Duplicate this one to change it.", "I prompt integrati sono di sola lettura. Duplica questo per modificarlo."),
        ]
        for (key, expected) in pairs {
            #expect(String(localized: String.LocalizationValue(key), bundle: bundle) == expected, "\(key)")
        }
    }
}
