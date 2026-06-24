import Foundation
import Testing
@testable import Parola

@Suite("Export failure message")
struct ExportFailureMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("an export failure surfaces the Italian message")
    func localizesExportFailure() throws {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "La cartella non esiste."]
        )
        let message = AppModel.exportFailureMessage(for: error, bundle: try italianBundle())
        #expect(message == "Esportazione non riuscita: La cartella non esiste.")
    }
}
