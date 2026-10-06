import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Recovery prompt copy")
struct RecoveryPromptCopyTests {
    private func checkpoint(_ kind: RecoveryCheckpoint.Kind, source: URL? = nil, title: String? = nil) -> RecoveryCheckpoint {
        RecoveryCheckpoint(kind: kind, startedAt: Date(), modelName: "m", sourceURL: source, language: "en", segments: [], title: title)
    }

    @Test("a recording's buttons say they open it or save it, and the message only says what happened")
    func recording() {
        let take = checkpoint(.recording)
        #expect(RecoveryPromptCopy.accept(take) == "Open Recording")
        #expect(RecoveryPromptCopy.decline(take) == "Save to Library")
        #expect(RecoveryPromptCopy.message(take) == "Parola quit while recording.")
    }

    @Test("a take cut off while transcribing offers to transcribe it or save it without a transcript")
    func takeBeingTranscribed() {
        let take = checkpoint(.fileTranscription, source: URL(fileURLWithPath: "/tmp/take.m4a"), title: "Standup")
        #expect(take.isTake)
        #expect(RecoveryPromptCopy.accept(take) == "Transcribe")
        #expect(RecoveryPromptCopy.decline(take) == "Save Without Transcript")
        #expect(RecoveryPromptCopy.message(take) == "Parola quit while transcribing Standup.")
    }

    @Test("a file the user opened keeps Transcribe and Not Now: nothing of it is lost")
    func openedFile() {
        let file = checkpoint(.fileTranscription, source: URL(fileURLWithPath: "/tmp/interview.m4a"))
        #expect(RecoveryPromptCopy.accept(file) == "Transcribe")
        #expect(RecoveryPromptCopy.decline(file) == "Not Now")
        #expect(RecoveryPromptCopy.message(file) == "Parola quit while transcribing interview.m4a.")
    }

    @Test("the buttons read in Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let take = checkpoint(.recording)
        #expect(RecoveryPromptCopy.accept(take, bundle: bundle) == "Apri registrazione")
        #expect(RecoveryPromptCopy.decline(take, bundle: bundle) == "Salva nella libreria")
        #expect(RecoveryPromptCopy.message(take, bundle: bundle) == "Parola si è chiusa durante una registrazione.")
        let transcribing = checkpoint(.fileTranscription, source: URL(fileURLWithPath: "/tmp/take.m4a"), title: "Standup")
        #expect(RecoveryPromptCopy.decline(transcribing, bundle: bundle) == "Salva senza trascrizione")
    }
}
