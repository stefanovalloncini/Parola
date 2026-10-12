import Testing
import Foundation
import CoreTransferable
@testable import Parola
import ParolaCore

@Suite("TranscriptShareItem")
struct TranscriptShareItemTests {
    @available(iOS 18.2, *)
    @Test("exports the transcript text only when asked for it")
    func exportsText() async throws {
        let transcript = Fixtures.makeTranscript()
        let item = TranscriptShareItem(transcript: transcript)
        let data = try await item.exported(as: .utf8PlainText)
        #expect(String(decoding: data, as: UTF8.self) == transcript.text)
    }
}
