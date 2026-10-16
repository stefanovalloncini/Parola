import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Webhook header validation")
struct WebhookHeaderValidationTests {
    private let named = WebhookHeader(name: "X-Key", secretRef: "ref-a")

    @Test("nothing is reported about a missing value until the Keychain lookup has answered")
    func loadingReportsNoMissingValue() {
        #expect(WebhookHeaderValidation.problem(headers: [named], typed: [:], saved: nil) == nil)
        #expect(WebhookHeaderValidation.problem(headers: [named], typed: [:], saved: []) == .missingValue)
    }

    @Test("a saved or typed value satisfies a header")
    func valueSatisfies() {
        #expect(WebhookHeaderValidation.problem(headers: [named], typed: [:], saved: ["ref-a"]) == nil)
        #expect(WebhookHeaderValidation.problem(headers: [named], typed: [named.id: "v"], saved: []) == nil)
    }

    @Test("a blank name is reported even while loading")
    func blankName() {
        let blank = WebhookHeader(name: "  ", secretRef: "ref-b")
        #expect(WebhookHeaderValidation.problem(headers: [named, blank], typed: [:], saved: nil) == .blankName)
    }

    @Test("a form with no headers is fine")
    func noHeaders() {
        #expect(WebhookHeaderValidation.problem(headers: [], typed: [:], saved: []) == nil)
    }
}
