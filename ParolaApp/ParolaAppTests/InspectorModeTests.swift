import Foundation
import Testing
@testable import Parola

@Suite("Inspector mode decoding")
struct InspectorModeTests {

    @Test("the inspector offers Format and Info only")
    func twoTabs() {
        #expect(InspectorMode.allCases == [.format, .info])
    }

    @Test("a stored value round-trips")
    func knownValuesRoundTrip() {
        #expect(InspectorMode(stored: "format") == .format)
        #expect(InspectorMode(stored: "info") == .info)
    }

    @Test("a value stored by the build that had an Actions tab lands on Info")
    func actionsFallsBackToInfo() {
        #expect(InspectorMode(stored: "actions") == .info)
    }

    @Test("an unknown stored value falls back to Format")
    func unknownFallsBackToFormat() {
        #expect(InspectorMode(stored: "garbage") == .format)
        #expect(InspectorMode(stored: "") == .format)
    }
}
