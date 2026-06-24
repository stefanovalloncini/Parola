import Foundation
import Testing
@testable import Parola

@Suite("Prompt failure message")
struct PromptFailureMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private let reason = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

    @Test("a prompt failure shows the Italian prefix and keeps the reason")
    func localizesPrompt() throws {
        let message = AppModel.promptFailureMessage(.prompt, error: reason, bundle: try italianBundle())
        #expect(message == "Prompt non riuscito: boom")
    }

    @Test("an action-item extraction failure is localized")
    func localizesActionItems() throws {
        let message = AppModel.promptFailureMessage(.actionItems, error: reason, bundle: try italianBundle())
        #expect(message == "Estrazione delle azioni non riuscita: boom")
    }

    @Test("a chapter extraction failure is localized")
    func localizesChapterExtraction() throws {
        let message = AppModel.promptFailureMessage(.chapterExtraction, error: reason, bundle: try italianBundle())
        #expect(message == "Estrazione dei capitoli non riuscita: boom")
    }

    @Test("a chapter generation failure is localized")
    func localizesChapterGeneration() throws {
        let message = AppModel.promptFailureMessage(.chapterGeneration, error: reason, bundle: try italianBundle())
        #expect(message == "Generazione dei capitoli non riuscita: boom")
    }
}
