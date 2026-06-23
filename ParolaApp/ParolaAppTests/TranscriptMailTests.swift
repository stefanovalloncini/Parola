import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Transcript mail")
struct TranscriptMailTests {
    private func transcript(_ segments: [(Int, Double, Double, String, String?)]) -> Transcript {
        Transcript(
            schemaVersion: 1,
            segments: segments.map {
                TranscriptSegment(id: $0.0, start: $0.1, end: $0.2, text: $0.3, speaker: $0.4)
            },
            language: "it",
            modelName: "x"
        )
    }

    private func bodyOf(_ url: URL?) -> String? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first { $0.name == "body" }?.value
    }

    private func subjectOf(_ url: URL?) -> String? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first { $0.name == "subject" }?.value
    }

    @Test("body matches the canonical timestamped render")
    func bodyMatchesRender() {
        let t = transcript([
            (1, 0, 2, "Hello", ""),
            (2, 5, 7, "   ", nil),
            (3, 90, 95, "World", "Marco\nRossi"),
        ])
        let url = TranscriptMail.mailtoURL(title: "Meeting", transcript: t)
        #expect(bodyOf(url) == "00:00  Hello\n01:30  Marco Rossi: World")
        #expect(bodyOf(url) == TranscriptTimestampedText.render(t))
    }

    @Test("body drops empty segments and the stray colon from an empty speaker")
    func bodyHasNoLeaks() {
        let t = transcript([
            (1, 0, 2, "Hello", ""),
            (2, 5, 7, "   ", nil),
            (3, 90, 95, "World", "Marco\nRossi"),
        ])
        let body = bodyOf(TranscriptMail.mailtoURL(title: "x", transcript: t)) ?? ""
        #expect(!body.contains("  : "))
        #expect(!body.contains("00:05"))
        #expect(!body.contains("Marco\nRossi"))
    }

    @Test("subject carries the title and the URL is a mailto link")
    func subjectAndScheme() {
        let url = TranscriptMail.mailtoURL(title: "Stand-up notes", transcript: transcript([(1, 0, 2, "Hi", nil)]))
        #expect(url?.scheme == "mailto")
        #expect(subjectOf(url) == "Stand-up notes")
    }

    @Test("an empty transcript still yields a mailto link with an empty body")
    func emptyTranscript() {
        let url = TranscriptMail.mailtoURL(title: "Empty", transcript: transcript([]))
        #expect(url?.scheme == "mailto")
        #expect(bodyOf(url) == "")
    }
}
