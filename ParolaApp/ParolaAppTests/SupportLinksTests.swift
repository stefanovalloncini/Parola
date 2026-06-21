import Foundation
import Testing
@testable import Parola

@Suite("Support links")
struct SupportLinksTests {
    @Test("repository points at the GitHub repo")
    func repository() {
        #expect(SupportLinks.repository.absoluteString == "https://github.com/stefanovalloncini/Parola")
    }

    @Test("feedback email is the author inbox, not the placeholder domain")
    func feedbackEmail() {
        #expect(SupportLinks.feedbackEmail == "stefano.valloncini@gmail.com")
        #expect(!SupportLinks.feedbackEmail.hasSuffix("@parola.app"))
    }

    @Test("feedback mailto is a valid mailto URL carrying a subject")
    func feedbackMailto() {
        let url = SupportLinks.feedbackMailto
        #expect(url?.scheme == "mailto")
        #expect(url?.absoluteString.contains("subject=") == true)
        #expect(url?.absoluteString.contains("stefano.valloncini@gmail.com") == true)
    }
}
