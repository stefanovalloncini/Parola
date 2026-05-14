import Testing
@testable import Parola

@Suite("Smoke")
struct SmokeTests {
    @Test("test target compiles and links the app target")
    func smoke() {
        #expect(Bool(true))
    }
}
